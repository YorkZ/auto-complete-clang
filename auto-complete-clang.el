;;; auto-complete-clang.el --- Auto Completion source for clang for GNU Emacs

;; Copyright (C) 2010  Brian Jiang
;; Copyright (C) 2012-2013 York Zhao

;; Author: Brian Jiang <brianjcj@gmail.com>
;;         York Zhao <gtdplatform@gmail.com>
;; Keywords: completion, convenience
;; Version: 0.1h

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.


;;; Commentary:
;;
;; Auto Completion source for clang. Most of codes are taken from
;; company-clang.el and modified and enhanced for Auto Completion.

;;; Code:

(provide 'auto-complete-clang)
(require 'auto-complete)

(defcustom ac-clang-executable
  (executable-find "clang")
  "*Location of clang executable"
  :group 'auto-complete
  :type 'file)

(defcustom ac-clang-auto-save nil
  "*Determines whether to save the buffer when retrieving completions.
Old version of clang can only complete correctly when the buffer has been saved.
Now clang can parse the codes from standard input so that we can turn this option
to Off. If you are still using the old clang, turn it on!"
  :group 'auto-complete
  :type '(choice (const :tag "Off" nil)
                 (const :tag "On" t)))

(defcustom ac-clang-lang-option-function nil
  "*function to return the lang type for option -x."
  :group 'auto-complete
  :type 'function)

;;; Extra compilation flags to pass to clang.
(defcustom ac-clang-flags nil
  "Extra flags to pass to the Clang executable.
This variable will typically contain include paths, e.g., ( \"-I~/MyProject\", \"-I.\" )."
  :group 'auto-complete
  :type '(repeat (string :tag "Argument" "")))
(put 'ac-clang-flags 'safe-local-variable 'listp)
(put 'ac-clang-prefix-header 'safe-local-variable 'listp)

;;; Whether to call clang asynchronously
(defcustom ac-clang-asynchronous nil
  "Whether or not to call clang asynchronously"
  :group 'auto-complete
  :type 'boolean)

(defface ac-clang-candidate-face
  '((t (:background "lightgray" :foreground "navy")))
  "Face for clang candidate"
  :group 'auto-complete)

(defface ac-clang-selection-face
  '((t (:background "navy" :foreground "white")))
  "Face for the clang selected candidate."
  :group 'auto-complete)

;;; The prefix header to use with Clang code completion. 
(defvar ac-clang-prefix-header nil)

(defvar ac-clang-process nil)
(defvar ac-clang-prefix "")
(defvar ac-clang-results nil)
(defvar ac-clang-last-prefix-point nil)
(defvar ac-clang-no-candidate-from nil)

(defvar ac-template-start-point nil)
(defvar ac-template-candidates (list "ok" "no" "yes:)"))

(defvar ac-clang-speck-window-suspend-list nil)

(defun ac-clang-suspend-speck ()
  (when speck-mode
    (setq ac-clang-speck-window-suspend-list
          (delq nil
                (mapcar #'(lambda (window)
                            (when (memq window speck-window-list)
                              window))
                 `(,(selected-window) ,(next-window)))))
    (mapc #'(lambda (window)
              (setq speck-window-list
                    (delq window speck-window-list)))
          ac-clang-speck-window-suspend-list)))

(defun ac-clang-desuspend-speck ()
  (when speck-mode
    (mapc #'(lambda (window)
              (unless (memq window speck-window-list)
                (with-current-buffer (window-buffer window)
                  (setq speck-window-list
                        (cons window speck-window-list)))))
          ac-clang-speck-window-suspend-list)
    (setq ac-clang-speck-window-suspend-list nil)))

(defmacro ac-clang-with-speck-suspended (&rest body)
  "If `speck-mode' is on, deactivate it, execute BODY and
activate it again."
  (declare (indent 0) (debug t))
  `(if speck-mode
       (progn
         (ac-clang-suspend-speck)
         (unwind-protect
             ,@body
           ;; Have to re-activate `speck' after 0.1 - 2 sec. If re-activate
           ;; immediately `auto-complete' candidate menu would not show up until
           ;; `speck' is done.
           (run-at-time 0.2 nil 'ac-clang-desuspend-speck)))
     ,@body))

;;; Set the Clang prefix header
(defun ac-clang-set-prefix-header (ph)
  (interactive
   (let ((def (car (directory-files "." t "\\([^.]h\\|[^h]\\).pch\\'" t))))
     (list
      (read-file-name
       (concat "Clang prefix header(current: " ac-clang-prefix-header ") : ")
                      (when def (file-name-directory def))
                      def nil (when def (file-name-nondirectory def))))))
  (cond ((string-match "^[\s\t]*$" ph)
         (setq ac-clang-prefix-header nil))
        (t
         (setq ac-clang-prefix-header ph))))

;;; Set a new cflags for clang
(defun ac-clang-set-cflags ()
  "set new cflags for clang from input string"
  (interactive)
  (setq ac-clang-flags (split-string (read-string "New cflags: "))))

;;; Set new cflags from shell command output
(defun ac-clang-set-cflags-from-shell-command ()
  "set new cflags for ac-clang from shell command output"
  (interactive)
  (setq ac-clang-flags
    (split-string
     (shell-command-to-string
      (read-shell-command "Shell command: " nil nil
                          (and buffer-file-name
                               (file-relative-name buffer-file-name)))))))

(defconst ac-clang-completion-pattern
  "^COMPLETION: \\(%s[^\s\n:]*\\)\\(?: : \\)*\\(.*$\\)")

(defconst ac-clang-error-buffer-name "*clang error*")

(defun ac-clang-parse-output (prefix)
  (goto-char (point-min))
  (let ((pattern (format ac-clang-completion-pattern
                         (regexp-quote prefix)))
        lines match detailed_info
        (prev-match ""))
    (while (re-search-forward pattern nil t)
      (setq match (match-string-no-properties 1))
      (unless (string= "Pattern" match)
        (setq detailed_info (match-string-no-properties 2))
        (if (string= match prev-match)
          (when detailed_info
            (setq match
                  (propertize match
                              'ac-clang-help
                              (concat
                               (get-text-property 0 'ac-clang-help
                                                  (car lines))
                               "\n"
                               detailed_info)))
            (setf (car lines) match))
          (setq prev-match match)
          (when detailed_info
            (setq match (propertize match 'ac-clang-help detailed_info)))
          (push match lines))))    
    lines))

(defun ac-clang-handle-error (res args)
  (goto-char (point-min))
  (let* ((buf (get-buffer-create ac-clang-error-buffer-name))
         (cmd (concat ac-clang-executable " " (mapconcat 'identity args " ")))
         (pattern (format ac-clang-completion-pattern ""))
         (err (if (re-search-forward pattern nil t)
                  (buffer-substring-no-properties (point-min)
                                                  (1- (match-beginning 0)))
                ;; Warn the user more agressively if no match was found.
                (message "clang failed with error %d:\n%s" res cmd)
                (buffer-string))))

    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (current-time-string)
                (format "\nclang failed with error %d:\n" res)
                cmd "\n\n")
        (insert err)
        (setq buffer-read-only t)
        (goto-char (point-min))))))

(defun ac-clang-call-process (prefix &rest args)
  (let ((buf (get-buffer-create "*clang-output*"))
        res)
    (with-current-buffer buf (erase-buffer))
    (setq res (if ac-clang-auto-save
                  (apply 'call-process ac-clang-executable nil buf nil args)
                (apply 'call-process-region (point-min) (point-max)
                       ac-clang-executable nil buf nil args)))
    (with-current-buffer buf
      (unless (eq 0 res)
        (ac-clang-handle-error res args))
      ;; Still try to get any useful input.
      (ac-clang-parse-output prefix))))

(defun ac-clang-filter (proc output)
  (with-current-buffer (process-buffer proc)
    (goto-char (point-max))
    (insert output)))

(defun ac-clang-sentinel (proc result)
  (when (eq (process-status proc) 'exit)
    (setq ac-clang-process nil)
    (with-current-buffer (process-buffer proc)
      (message "Received raw output from clang")
      (setq ac-clang-results (ac-clang-parse-output ac-clang-prefix))
      (message "Parsed clang output"))
      ;; it is critical to complete members, so 
      ;; we force ac-start to show up.
    (ac-start :force-init t)
    (ac-update)))

(defun ac-clang-start-process (prefix &rest args)
  ;; Start clang process asynchronously
  (if ac-clang-results
      ;; The asynchronous clang process has finished and completion results are
      ;; available.
      (prog1
          ac-clang-results
        ;; Reset completion results
        (setq ac-clang-results nil)
        (message "Received clang completion results"))
    (if ac-clang-process
        ;; The previous clang process is still running, we have to be patient
        (message "Clang process still running")
      (let ((buf (get-buffer-create "*clang-output*")))
        (with-current-buffer buf
          (erase-buffer))
        (setq ac-clang-prefix ac-prefix)
        (setq ac-clang-process
              (apply 'start-process
                     "clang" buf ac-clang-executable args))
        (unless ac-clang-auto-save
          (process-send-region ac-clang-process (point-min) (point))
          (process-send-eof ac-clang-process))
        (set-process-sentinel ac-clang-process 'ac-clang-sentinel)
        (set-process-filter ac-clang-process 'ac-clang-filter)
        (message "Started clang process")))
    nil))

(defsubst ac-clang-build-location (pos)
  (save-excursion
    (goto-char pos)
    (format "%s:%d:%d"
            (if ac-clang-auto-save buffer-file-name "-")
            (line-number-at-pos)
            (1+ (- (point) (line-beginning-position))))))

(defsubst ac-clang-lang-option ()
  (or (and ac-clang-lang-option-function
           (funcall ac-clang-lang-option-function))
      (cond ((eq major-mode 'c++-mode)
             "c++")
            ((eq major-mode 'c-mode)
             "c")
            ((eq major-mode 'objc-mode)
             (cond ((string= "m" (file-name-extension (buffer-file-name)))
                    "objective-c")
                   (t
                    "objective-c++")))
            (t
             "c++"))))

(defsubst ac-clang-build-complete-args (pos)
  (append '("-cc1" "-fsyntax-only")
          (unless ac-clang-auto-save
            (list "-x" (ac-clang-lang-option)))
          ac-clang-flags
          (when (stringp ac-clang-prefix-header)
            (list "-include-pch" (expand-file-name ac-clang-prefix-header)))
          '("-code-completion-at")
          (list (ac-clang-build-location pos))
          (list (if ac-clang-auto-save buffer-file-name "-"))))

(defsubst ac-clang-clean-document (s)
  (when s
    (setq s (replace-regexp-in-string "<#\\|#>\\|\\[#" "" s))
    (setq s (replace-regexp-in-string "#\\]" " " s)))
  s)

(defun ac-clang-document (item)
  (if (stringp item)
      (let (s)
        (setq s (get-text-property 0 'ac-clang-help item))
        (ac-clang-clean-document s))))

(defun ac-clang-candidate ()
  (cl-labels
      ((;; Auxiliary function  `no-prefix-p'
        no-prefix-p
        nil
        (let ((ch (char-before)))
          (and (string= ac-prefix "")
               (not (eq ch ?\.))
               ;; ->
               (not (and (eq ch ?>)
                         (eq (char-before (1- (point))) ?-)))
               ;; ::
               (not (and (eq ch ?:)
                         (eq (char-before (1- (point))) ?:)))))))
    (unless (or (and ac-clang-no-candidate-from
                     (>= (point) ac-clang-no-candidate-from))
                (no-prefix-p)
                (memq (get-text-property (point) 'face)
                      '(font-lock-comment-face
                        font-lock-comment-delimiter-face
                        font-lock-string-face)))
      (and ac-clang-auto-save
           (buffer-modified-p)
           (basic-save-buffer))
      (save-restriction
        (widen)
        (ac-clang-with-speck-suspended
          (let ((candidates (apply (if ac-clang-asynchronous
                                       'ac-clang-start-process
                                     'ac-clang-call-process)
                                   ac-prefix
                                   (ac-clang-build-complete-args
                                    (- (point) (length ac-prefix))))))
            (unless candidates
              (setq ac-clang-no-candidate-from (point)))
            candidates))))))

(defun ac-clang-action ()
  (interactive)
  ;; (ac-last-quick-help)
  (let ((help (ac-clang-clean-document
               (get-text-property 0 'ac-clang-help (cdr ac-last-completion))))
        (raw-help (get-text-property 0 'ac-clang-help (cdr ac-last-completion)))
        (candidates (list))
        ss fn args
        (ret-t "") ret-f)
    (setq ss (split-string raw-help "\n"))
    (dolist (s ss)
      (when (string-match "\\[#\\(.*?\\)#\\]" s)
        (setq ret-t (match-string 1 s)))
      (setq s (replace-regexp-in-string "\\[#.*?#\\]" "" s))
      (cond ((string-match "^\\([^(]*\\)\\((.*)\\)" s)
             (setq fn (match-string 1 s)
                   args (match-string 2 s))
             (push (propertize (ac-clang-clean-document args)
                               'ac-clang-help ret-t 'raw-args args)
                   candidates)
             (when (string-match "\{#" args)
               (setq args (replace-regexp-in-string "\{#.*#\}" "" args))
               (push (propertize (ac-clang-clean-document args)
                                 'ac-clang-help ret-t 'raw-args args)
                     candidates))
             (when (string-match ", \\.\\.\\." args)
               (setq args (replace-regexp-in-string ", \\.\\.\\." "" args))
               (push (propertize (ac-clang-clean-document args)
                                 'ac-clang-help ret-t 'raw-args args)
                     candidates)))
            ;; check whether it is a function ptr
            ((string-match "^\\([^(]*\\)(\\*)\\((.*)\\)" ret-t)
             (setq ret-f (match-string 1 ret-t)
                   args (match-string 2 ret-t))
             (push (propertize args 'ac-clang-help ret-f 'raw-args "")
                   candidates)
             (when (string-match ", \\.\\.\\." args)
               (setq args (replace-regexp-in-string ", \\.\\.\\." "" args))
               (push (propertize args 'ac-clang-help ret-f 'raw-args "")
                     candidates)))))
    (cond (candidates
           (setq candidates (delete-dups candidates))
           (setq candidates (nreverse candidates))
           (setq ac-template-candidates candidates)
           (setq ac-template-start-point (point))
           (ac-complete-template)
           
           (unless (cdr candidates) ;; unless length > 1
             (message (replace-regexp-in-string "\n" "   ;    " help))))
          (t
           (message (replace-regexp-in-string "\n" "   ;    " help))))))

(defun ac-clang-prefix ()
  (let* ((char (char-before))
         (prefix-point
          (or (ac-prefix-symbol)
              (when (or (eq ?\. char)
                        ;; ->
                        (and (eq ?> char)
                             (eq ?- (char-before (1- (point)))))
                        ;; ::
                        (and (eq ?: char)
                             (eq ?: (char-before (1- (point))))))
                (point)))))
    (unless (eq ac-clang-last-prefix-point prefix-point)
      (setq ac-clang-last-prefix-point prefix-point
            ;; Reset `ac-clang-no-candidate-from' when prefix point changes
            ac-clang-no-candidate-from nil))
    prefix-point))

(defun ac-clang-same-count-in-string (c1 c2 s)
  (let ((count 0) (cur 0) (end (length s)) c)
    (while (< cur end)
      (setq c (aref s cur))
      (cond ((eq c1 c)
             (setq count (1+ count)))
            ((eq c2 c)
             (setq count (1- count))))
      (setq cur (1+ cur)))
    (= count 0)))

(defun ac-clang-split-args (s)
  (let ((sl (split-string s ", *")))
    (cond ((string-match "<\\|(" s)
           (let ((res (list)) (pre "") subs)
             (while sl
               (setq subs (pop sl))
               (unless (string= pre "")
                 (setq subs (concat pre ", " subs))
                 (setq pre ""))
               (cond ((and (ac-clang-same-count-in-string ?\< ?\> subs)
                           (ac-clang-same-count-in-string ?\( ?\) subs))
                      (push subs res))
                     (t
                      (setq pre subs))))
             (nreverse res)))
          (t
           sl))))

(defun ac-template-candidate ()
  ac-template-candidates)

(defun ac-template-action ()
  (interactive)
  (unless (null ac-template-start-point)
    (let ((pos (point)) sl (snp "")
          (s (get-text-property 0 'raw-args (cdr ac-last-completion))))
      (cond ((string= s "")
             ;; function ptr call
             (setq s (cdr ac-last-completion))
             (setq s (replace-regexp-in-string "^(\\|)$" "" s))
             (setq sl (ac-clang-split-args s))
             (cond ((featurep 'yasnippet)
                    (dolist (arg sl)
                      (setq snp (concat snp ", ${" arg "}")))
                    (condition-case nil
                        (yas-expand-snippet (concat "("  (substring snp 2) ")")
                                            ac-template-start-point pos) ;; 0.6.1c
                      (error
                       ;; try this one:
                       (ignore-errors (yas-expand-snippet
                                       ac-template-start-point pos
                                       (concat "("  (substring snp 2) ")"))) ;; work in 0.5.7
                       )))
                   ((featurep 'snippet)
                    (delete-region ac-template-start-point pos)
                    (dolist (arg sl)
                      (setq snp (concat snp ", $${" arg "}")))
                    (snippet-insert (concat "("  (substring snp 2) ")")))
                   (t
                    (message "Dude! You are too out! Please install a yasnippet or a snippet script:)"))))
             (t
             (unless (string= s "()")
               (setq s (replace-regexp-in-string "{#" "" s))
               (setq s (replace-regexp-in-string "#}" "" s))
               (cond ((featurep 'yasnippet)
                      (setq s (replace-regexp-in-string "<#" "${" s))
                      (setq s (replace-regexp-in-string "#>" "}" s))
                      (setq s (replace-regexp-in-string ", \\.\\.\\." "}, ${..." s))
                      (condition-case nil
                          ;; 0.6.1c
                          (yas-expand-snippet s ac-template-start-point pos)
                        (error
                         ;; try this one:
                         (ignore-errors
                           ;; work in 0.5.7
                           (yas-expand-snippet ac-template-start-point pos s)))))
                     ((featurep 'snippet)
                      (delete-region ac-template-start-point pos)
                      (setq s (replace-regexp-in-string "<#" "$${" s))
                      (setq s (replace-regexp-in-string "#>" "}" s))
                      (setq s (replace-regexp-in-string ", \\.\\.\\." "}, $${..." s))
                      (snippet-insert s))
                     (t
                      (message "Dude! You are too out! Please install a yasnippet or a snippet script:)")))))))))

(defun ac-template-prefix ()
  ac-template-start-point)

(ac-define-source clang
  '((candidates . ac-clang-candidate)
    (candidate-face . ac-clang-candidate-face)
    (selection-face . ac-clang-selection-face)
    (prefix . ac-clang-prefix)
    (requires . 0)
    (document . ac-clang-document)
    (action . ac-clang-action)
    (cache)
    (symbol . "c")))

;; this source shall only be used internally.
(ac-define-source template
  '((candidates . ac-template-candidate)
    (prefix . ac-template-prefix)
    (requires . 0)
    (action . ac-template-action)
    (document . ac-clang-document)
    (cache)
    (symbol . "t")))

;;; auto-complete-clang.el ends here
