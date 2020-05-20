;;; monky.el --- Control Hg  -*- lexical-binding: t; -*-

;; Copyright (C) 2011 Anantha Kumaran.

;; Author: Anantha Kumaran <ananthakumaran@gmail.com>
;; URL: http://github.com/ananthakumaran/monky
;; Version: 0.2
;; Keywords: tools
;; Package-Requires: ((emacs "24.4"))

;; Monky is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; Monky is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

(require 'cl)
(require 'cl-lib)
(require 'bindat)
(require 'ediff)
(require 'subr-x)
(require 'view)
(require 'tramp)

(defgroup monky nil
  "Controlling Hg from Emacs."
  :prefix "monky-"
  :group 'tools)

(defcustom monky-hg-executable "hg"
  "The name of the Hg executable."
  :group 'monky
  :type 'string)

(defcustom monky-hg-standard-options '("--config" "diff.git=Off" "--config" "ui.merge=:merge")
  "Standard options when running Hg."
  :group 'monky
  :type '(repeat string))

(defcustom monky-hg-process-environment '("TERM=dumb" "HGPLAIN=" "LANGUAGE=C")
  "Default environment variables for hg."
  :group 'monky
  :type '(repeat string))

;; TODO
(defcustom monky-save-some-buffers t
  "Non-nil means that \\[monky-status] will save modified buffers before running.
Setting this to t will ask which buffers to save, setting it to 'dontask will
save all modified buffers without asking."
  :group 'monky
  :type '(choice (const :tag "Never" nil)
                 (const :tag "Ask" t)
                 (const :tag "Save without asking" dontask)))

(defcustom monky-revert-item-confirm t
  "Require acknowledgment before reverting an item."
  :group 'monky
  :type 'boolean)

(defcustom monky-log-edit-confirm-cancellation nil
  "Require acknowledgment before canceling the log edit buffer."
  :group 'monky
  :type 'boolean)

(defcustom monky-process-popup-time -1
  "Popup the process buffer if a command takes longer than this many seconds."
  :group 'monky
  :type '(choice (const :tag "Never" -1)
                 (const :tag "Immediately" 0)
                 (integer :tag "After this many seconds")))

(defcustom monky-log-cutoff-length 100
  "The maximum number of commits to show in the log buffer."
  :group 'monky
  :type 'integer)

(defcustom monky-log-infinite-length 99999
  "Number of log used to show as maximum for `monky-log-cutoff-length'."
  :group 'monky
  :type 'integer)

(defcustom monky-log-auto-more t
  "Insert more log entries automatically when moving past the last entry.

Only considered when moving past the last entry with `monky-goto-next-section'."
  :group 'monky
  :type 'boolean)

(defcustom monky-incoming-repository "default"
  "The repository from which changes are pulled from by default."
  :group 'monky
  :type 'string)

(defcustom monky-outgoing-repository ""
  "The repository to which changes are pushed to by default."
  :group 'monky
  :type 'string)

(defcustom monky-process-type nil
  "How monky spawns Mercurial processes.
Monky can either spawn a new Mercurial process for each request or
use Mercurial's command server feature to run several commands in a
single process instances. While the former is more robust, the latter
is usually faster if Monky runs several commands."
  :group 'monky
  :type '(choice (const :tag "Single processes" :value nil)
                 (const :tag "Use command server" :value cmdserver)))

(defcustom monky-pull-args ()
  "Extra args to pass to pull."
  :group 'monky
  :type '(repeat string))

(defcustom monky-repository-paths nil
  "*Paths where to find repositories.  For each repository an alias is defined, which can then be passed to `monky-open-repository` to open the repository.

Lisp-type of this option: The value must be a list L whereas each
element of L is a 2-element list: The first element is the full
path of a directory \(string) and the second element is an
arbitrary alias \(string) for this directory which is then
displayed instead of the underlying directory."
  :group 'monky
  :initialize 'custom-initialize-default
  :set (function (lambda (symbol value)
                   (set symbol value)
                   (if (and (boundp 'ecb-minor-mode)
                            ecb-minor-mode
			    (functionp 'ecb-update-directories-buffer))
		       (ecb-update-directories-buffer))))
  :type '(repeat (cons :tag "Path with alias"
		       (string :tag "Alias")
		       (directory :tag "Path"))))

(defun monky-root-dir-descr (dir)
  "Return the name of dir if it matches a path in monky-repository-paths, otherwise return nil"
  (catch 'exit
    (dolist (root-dir monky-repository-paths)
      (let ((base-dir
	     (concat
	      (replace-regexp-in-string
	       "/$" ""
	       (replace-regexp-in-string
		"^\~" (getenv "HOME")
		(cdr root-dir)))
	      "/")))
	(when (equal base-dir dir)
	  (throw 'exit (cons (car root-dir)
			     base-dir)))))))

(defun monky-open-repository ()
  "Prompt for a repository path or alias, then display the status
buffer.  Aliases are set in monky-repository-paths."
  (interactive)
  (let* ((rootdir (condition-case nil
		      (monky-get-root-dir)
		    (error nil)))
	 (default-repo (or (monky-root-dir-descr rootdir) rootdir))
	 (msg (if default-repo
		  (concat "repository (default " (car default-repo) "): ")
		"repository: "))
	 (repo-name (completing-read msg (mapcar 'car monky-repository-paths)))
	 (repo (or (assoc repo-name monky-repository-paths) default-repo)))
    (when repo (monky-status (cdr repo)))))

(defgroup monky-faces nil
  "Customize the appearance of Monky"
  :prefix "monky-"
  :group 'faces
  :group 'monky)

(defface monky-header
  '((t :weight bold))
  "Face for generic header lines.

Many Monky faces inherit from this one by default."
  :group 'monky-faces)

(defface monky-section-title
  '((((class color) (background light)) :foreground "DarkGoldenrod4" :inherit monky-header)
    (((class color) (background  dark)) :foreground "LightGoldenrod2" :inherit monky-header))
  "Face for section titles."
  :group 'monky-faces)

(defface monky-branch
  '((t :weight bold :inherit monky-header))
  "Face for the current branch."
  :group 'monky-faces)

(defface monky-diff-title
  '((t :inherit (monky-header)))
  "Face for diff title lines."
  :group 'monky-faces)

(defface monky-diff-hunk-header
  '((((class color) (background light))
     :background "grey80"
     :foreground "grey30")
    (((class color) (background dark))
     :background "grey25"
     :foreground "grey70"))
  "Face for diff hunk header lines."
  :group 'monky-faces)

(defface monky-diff-add
  '((((class color) (background light))
     :background "#cceecc"
     :foreground "#22aa22")
    (((class color) (background dark))
     :background "#336633"
     :foreground "#cceecc"))
  "Face for lines in a diff that have been added."
  :group 'monky-faces)

(defface monky-diff-none
  '((t))
  "Face for lines in a diff that are unchanged."
  :group 'monky-faces)

(defface monky-diff-del
  '((((class color) (background light))
     :background "#eecccc"
     :foreground "#aa2222")
    (((class color) (background dark))
     :background "#663333"
     :foreground "#eecccc"))
  "Face for lines in a diff that have been deleted."
  :group 'monky-faces)

(defface monky-commit-id
  '((((class color) (background light))
     :foreground "firebrick")
    (((class color) (background dark))
     :foreground "tomato"))
  "Face for commit IDs: SHA1 codes and commit numbers."
  :group 'monky-faces)

(defface monky-log-sha1
  '((t :inherit monky-commit-id))
  "Face for the sha1 element of the log output."
  :group 'monky-faces)

(defface monky-log-message
  '((t))
  "Face for the message element of the log output."
  :group 'monky-faces)

(defface monky-log-author
  '((((class color) (background light))
     :foreground "navy")
    (((class color) (background dark))
     :foreground "cornflower blue"))
  "Face for author shown in log buffer."
  :group 'monky-faces)

(defface monky-log-head-label-local
  '((((class color) (background light))
     :box t
     :background "Grey85"
     :foreground "LightSkyBlue4")
    (((class color) (background dark))
     :box t
     :background "Grey13"
     :foreground "LightSkyBlue1"))
  "Face for local branch head labels shown in log buffer."
  :group 'monky-faces)

(defface monky-log-head-label-tags
  '((((class color) (background light))
     :box t
     :background "LemonChiffon1"
     :foreground "goldenrod4")
    (((class color) (background dark))
     :box t
     :background "LemonChiffon1"
     :foreground "goldenrod4"))
  "Face for tag labels shown in log buffer."
  :group 'monky-faces)

(defface monky-queue-patch
  '((t :weight bold :inherit (monky-header highlight)))
  "Face for patch name"
  :group 'monky-faces)

(defface monky-log-head-label-bookmarks
  '((((class color) (background light))
     :box t
     :background "IndianRed1"
     :foreground "IndianRed4")
    (((class color) (background dark))
     :box t
     :background "IndianRed1"
     :foreground "IndianRed4"))
  "Face for bookmark labels shown in log buffer."
  :group 'monky-faces)

(defface monky-log-head-label-phase
  '((((class color) (background light))
     :box t
     :background "light green"
     :foreground "dark olive green")
    (((class color) (background dark))
     :box t
     :background "light green"
     :foreground "dark olive green"))
  "Face for phase label shown in log buffer."
  :group 'monky-faces)

(defface monky-log-date
  '((t :weight bold :inherit monky-header))
  "Face for date in log."
  :group 'monky-faces)

(defface monky-queue-active
  '((((class color) (background light))
     :box t
     :background "light green"
     :foreground "dark olive green")
    (((class color) (background dark))
     :box t
     :background "light green"
     :foreground "dark olive green"))
  "Face for active patch queue"
  :group 'monky-faces)

(defface monky-queue-positive-guard
  '((((class color) (background light))
     :box t
     :background "light green"
     :foreground "dark olive green")
    (((class color) (background dark))
     :box t
     :background "light green"
     :foreground "dark olive green"))
  "Face for queue postive guards"
  :group 'monky-faces)

(defface monky-queue-negative-guard
  '((((class color) (background light))
     :box t
     :background "IndianRed1"
     :foreground "IndianRed4")
    (((class color) (background dark))
     :box t
     :background "IndianRed1"
     :foreground "IndianRed4"))
  "Face for queue negative guards"
  :group 'monky-faces)

(defvar monky-mode-hook nil
  "Hook run by `monky-mode'.")

;;; User facing configuration

(put 'monky-mode 'mode-class 'special)

;;; Compatibilities

;;; Utilities

(defmacro monky-with-process-environment (&rest body)
  (declare (indent 0)
           (debug (body)))
  `(let ((process-environment (append monky-hg-process-environment
                                      process-environment)))
     ,@body))

(defmacro monky-with-refresh (&rest body)
  "Refresh monky buffers after evaluating BODY.

It is safe to call the functions which uses this macro inside of
this macro.  As it is time consuming to refresh monky buffers,
this macro enforces refresh to occur exactly once by pending
refreshes inside of this macro.  Nested calls of this
macro (possibly via functions) does not refresh buffers multiple
times.  Instead, only the outside-most call of this macro
refreshes buffers."
  (declare (indent 0)
           (debug (body)))
  `(monky-refresh-wrapper (lambda () ,@body)))

(defun monky-completing-read (&rest args)
  (apply (if (null ido-mode)
             'completing-read
           'ido-completing-read)
         args))

(defun monky-start-process (&rest args)
  (monky-with-process-environment
    (apply (if (functionp 'start-file-process)
               'start-file-process
             'start-process) args)))

(defun monky-process-file-single (&rest args)
  (monky-with-process-environment
    (apply 'process-file args)))


;; Command server
(defvar monky-process nil)
(defvar monky-process-buffer-name "*monky-process*")
(defvar monky-process-client-buffer nil)

(defvar monky-cmd-process nil)
(defvar monky-cmd-process-buffer-name "*monky-cmd-process*")
(defvar monky-cmd-process-input-buffer nil)
(defvar monky-cmd-process-input-point nil)
(defvar monky-cmd-error-message nil)
(defvar monky-cmd-hello-message nil
  "Variable to store parsed hello message.")

;; TODO: does this need to be permanent? If it's only used in monky buffers (not source file buffers), it shouldn't be.
(defvar-local monky-root-dir nil)
(put 'monky-root-dir 'permanent-local t)

(defun monky-cmdserver-sentinel (proc _change)
  (unless (memq (process-status proc) '(run stop))
    (delete-process proc)))

(defun monky-cmdserver-read-data (size)
  (with-current-buffer (process-buffer monky-cmd-process)
    (while (< (point-max) size)
      (accept-process-output monky-cmd-process 0.1 nil t))
    (let ((str (buffer-substring (point-min) (+ (point-min) size))))
      (delete-region (point-min) (+ (point-min) size))
      (goto-char (point-min))
      (vconcat str))))

(defun monky-cmdserver-read ()
  "Read one channel and return cons (CHANNEL . RAW-DATA)."
  (let* ((data (bindat-unpack '((channel byte) (len u32))
                              (monky-cmdserver-read-data 5)))
         (channel (bindat-get-field data 'channel))
         (len (bindat-get-field data 'len)))
    (cons channel (monky-cmdserver-read-data len))))

(defun monky-cmdserver-unpack-int (data)
  (bindat-get-field (bindat-unpack '((field u32)) data) 'field))

(defun monky-cmdserver-unpack-string (data)
  (bindat-get-field (bindat-unpack `((field str ,(length data))) data) 'field))

(defun monky-cmdserver-write (data)
  (process-send-string monky-cmd-process
                       (concat (bindat-pack '((len u32))
                                            `((len . ,(length data))))
                               data)))

(defun monky-cmdserver-start ()
  (unless monky-root-dir
    (let (monky-process monky-process-type)
      (setq monky-root-dir (monky-get-root-dir))))

  (let ((dir monky-root-dir)
        (buf (get-buffer-create monky-cmd-process-buffer-name))
        (default-directory monky-root-dir)
        (process-connection-type nil))
    (with-current-buffer buf
      (setq buffer-read-only nil)
      (setq buffer-file-coding-system 'no-conversion)
      (set-buffer-multibyte nil)
      (erase-buffer)
      (setq view-exit-action
            #'(lambda (buffer)
                (with-current-buffer buffer
                  (bury-buffer))))
      (setq default-directory dir)
      (let ((monky-cmd-process (monky-start-process
                                "monky-hg" buf "sh" "-c"
                                (format "%s --config extensions.mq= serve --cmdserver pipe 2> /dev/null" monky-hg-executable))))
        (set-process-coding-system monky-cmd-process 'no-conversion 'no-conversion)
        (set-process-sentinel monky-cmd-process #'monky-cmdserver-sentinel)
        (setq monky-cmd-hello-message
              (monky-cmdserver-parse-hello (monky-cmdserver-read)))
        monky-cmd-process))))

(defun monky-cmdserver-parse-hello (hello-message)
  "Parse hello message to get encoding information."
  (let ((channel (car hello-message))
        (text (cdr hello-message)))
    (if (eq channel ?o)
        (progn
          (mapcar
           (lambda (s)
             (string-match "^\\([a-z0-9]+\\) *: *\\(.*\\)$" s)
             (let ((field-name (match-string 1 s))
                   (field-data (match-string 2 s)))
               (cons (intern field-name) field-data)))
           (split-string (monky-cmdserver-unpack-string text) "\n")))
      (error "unknown channel %c for hello message" channel))))

(defun monky-cmdserver-get-encoding (&optional default)
  "Get encoding stored in `monky-cmd-hello-message'."
  (let ((e (assoc 'encoding monky-cmd-hello-message)))
    (if e
        (cond
         ((string-equal (downcase (cdr e)) "ascii")
          'us-ascii)
         (t
          (intern (downcase (cdr e)))))
      default)))

(defun monky-cmdserver-runcommand (&rest cmd-and-args)
  (setq monky-cmd-error-message nil)
  (with-current-buffer (process-buffer monky-cmd-process)
    (setq buffer-read-only nil)
    (erase-buffer))
  (process-send-string monky-cmd-process "runcommand\n")
  (monky-cmdserver-write (mapconcat #'identity cmd-and-args "\0"))
  (let* ((inhibit-read-only t)
         (start (point))
         (result
          (catch 'finished
            (while t
              (let* ((result (monky-cmdserver-read))
                     (channel (car result))
                     (text (cdr result)))
                (cond
                 ((eq channel ?o)
                  (insert (monky-cmdserver-unpack-string text)))
                 ((eq channel ?r)
                  (throw 'finished
                         (monky-cmdserver-unpack-int text)))
                 ((eq channel ?e)
                  (setq monky-cmd-error-message
                        (concat monky-cmd-error-message text)))
                 ((memq channel '(?I ?L))
                  (with-current-buffer monky-cmd-process-input-buffer
                    (let* ((max (if (eq channel ?I)
                                    (point-max)
                                  (save-excursion
                                    (goto-char monky-cmd-process-input-point)
                                    (line-beginning-position 2))))
                           (maxreq (monky-cmdserver-unpack-int text))
                           (len (min (- max monky-cmd-process-input-point)
                                     maxreq))
                           (end (+ monky-cmd-process-input-point len)))
                      (monky-cmdserver-write
                       (buffer-substring monky-cmd-process-input-point end))
                      (setq monky-cmd-process-input-point end))))
                 (t
                  (setq monky-cmd-error-message
                        (format "Unsupported channel: %c" channel)))))))))
    (decode-coding-region start (point)
                          (monky-cmdserver-get-encoding 'utf-8))
    result))

(defun monky-cmdserver-process-file (program infile buffer display &rest args)
  "Same as `process-file' but uses the currently active hg command-server."
  (if (or infile display)
      (apply #'monky-process-file-single program infile buffer display args)
    (let ((stdout (if (consp buffer) (car buffer) buffer))
          (stderr (and (consp buffer) (cadr buffer))))
      (if (eq stdout t) (setq stdout (current-buffer)))
      (if (eq stderr t) (setq stderr stdout))
      (let ((result
             (if stdout
                 (with-current-buffer stdout
                   (apply #'monky-cmdserver-runcommand args))
               (with-temp-buffer
                 (apply #'monky-cmdserver-runcommand args)))))
        (cond
         ((bufferp stderr)
          (when monky-cmd-error-message
            (with-current-buffer stderr
              (insert monky-cmd-error-message))))
         ((stringp stderr)
          (with-temp-file stderr
            (when monky-cmd-error-message
              (insert monky-cmd-error-message)))))
        result))))

(defun monky-process-file (&rest args)
  "Same as `process-file' in the current hg environment.
This function either calls `monky-cmdserver-process-file' or
`monky-process-file-single' depending on whether the hg
command-server should be used."
  (apply (cond
          (monky-cmd-process #'monky-cmdserver-process-file)
          ;; ((eq monky-process-type 'cmdserver)
          ;;  (error "No process started (forget `monky-with-process`?)"))
          (t #'monky-process-file-single))
         args))

(defmacro monky-with-process (&rest body)
  (declare (indent 0)
	   (debug (body)))
  `(let ((outer (not monky-cmd-process)))
     (when (and outer (eq monky-process-type 'cmdserver))
       (setq monky-cmd-process (monky-cmdserver-start)))
     (unwind-protect
	 (progn ,@body)
       (when (and monky-cmd-process outer (eq monky-process-type 'cmdserver))
	 (delete-process monky-cmd-process)
	 (setq monky-cmd-process nil)))))



(defvar monky-bug-report-url "http://github.com/ananthakumaran/monky/issues")
(defun monky-bug-report (str)
  (message "Unknown error: %s\nPlease file a bug at %s"
           str monky-bug-report-url))

(defun monky-string-starts-with-p (string prefix)
  (eq (compare-strings string nil (length prefix) prefix nil nil) t))

(defun monky-trim-line (str)
  (if (string= str "")
      nil
    (if (equal (elt str (- (length str) 1)) ?\n)
        (substring str 0 (- (length str) 1))
      str)))

(defun monky-delete-line (&optional end)
  "Delete the text in current line.
If END is non-nil, deletes the text including the newline character"
  (let ((end-point (if end
                       (1+ (point-at-eol))
                     (point-at-eol))))
    (delete-region (point-at-bol) end-point)))

(defun monky-split-lines (str)
  (if (string= str "")
      nil
    (let ((lines (nreverse (split-string str "\n"))))
      (if (string= (car lines) "")
          (setq lines (cdr lines)))
      (nreverse lines))))

(defun monky-put-line-property (prop val)
  (put-text-property (line-beginning-position) (line-beginning-position 2)
                     prop val))

(defun monky-parse-args (command)
  (require 'pcomplete)
  (car (with-temp-buffer
         (insert command)
         (pcomplete-parse-buffer-arguments))))

(defun monky-prefix-p (prefix list)
  "Return non-nil if PREFIX is a prefix of LIST.
PREFIX and LIST should both be lists.

If the car of PREFIX is the symbol '*, then return non-nil if the cdr of PREFIX
is a sublist of LIST (as if '* matched zero or more arbitrary elements of LIST)"
  (or (null prefix)
      (if (eq (car prefix) '*)
          (or (monky-prefix-p (cdr prefix) list)
              (and (not (null list))
                   (monky-prefix-p prefix (cdr list))))
        (and (not (null list))
             (equal (car prefix) (car list))
             (monky-prefix-p (cdr prefix) (cdr list))))))

(defun monky-wash-sequence (func)
  "Run FUNC until end of buffer is reached.

FUNC should leave point at the end of the modified region"
  (while (and (not (eobp))
              (funcall func))))

(defun monky-goto-line (line)
  "Like `goto-line' but doesn't set the mark."
  (save-restriction
    (widen)
    (goto-char 1)
    (forward-line (1- line))))

;;; Key bindings

(defvar monky-mode-map
  (let ((map (make-keymap)))
    (suppress-keymap map t)
    (define-key map (kbd "n") 'monky-goto-next-section)
    (define-key map (kbd "p") 'monky-goto-previous-section)
    (define-key map (kbd "RET") 'monky-visit-item)
    (define-key map (kbd "TAB") 'monky-toggle-section)
    (define-key map (kbd "SPC") 'monky-show-item-or-scroll-up)
    (define-key map (kbd "DEL") 'monky-show-item-or-scroll-down)
    (define-key map (kbd "g") 'monky-refresh)
    (define-key map (kbd "$") 'monky-display-process)
    (define-key map (kbd ":") 'monky-hg-command)
    (define-key map (kbd "l l") 'monky-log-current-branch)
    (define-key map (kbd "l a") 'monky-log-all)
    (define-key map (kbd "l r") 'monky-log-revset)
    (define-key map (kbd "b") 'monky-branches)
    (define-key map (kbd "Q") 'monky-queue)
    (define-key map (kbd "q") 'monky-quit-window)

    (define-key map (kbd "M-1") 'monky-section-show-level-1-all)
    (define-key map (kbd "M-2") 'monky-section-show-level-2-all)
    (define-key map (kbd "M-3") 'monky-section-show-level-3-all)
    (define-key map (kbd "M-4") 'monky-section-show-level-4-all)
    map))

(defvar monky-status-mode-map
  (let ((map (make-keymap)))
    (define-key map (kbd "s") 'monky-stage-item)
    (define-key map (kbd "S") 'monky-stage-all)
    (define-key map (kbd "u") 'monky-unstage-item)
    (define-key map (kbd "U") 'monky-unstage-all)
    (define-key map (kbd "a") 'monky-commit-amend)
    (define-key map (kbd "c") 'monky-log-edit)
    (define-key map (kbd "e") 'monky-ediff-item)
    (define-key map (kbd "y") 'monky-bookmark-create)
    (define-key map (kbd "C") 'monky-checkout)
    (define-key map (kbd "M") 'monky-merge)
    (define-key map (kbd "B") 'monky-backout)
    (define-key map (kbd "P") 'monky-push)
    (define-key map (kbd "f") 'monky-pull)
    (define-key map (kbd "k") 'monky-discard-item)
    (define-key map (kbd "m") 'monky-resolve-item)
    (define-key map (kbd "x") 'monky-unresolve-item)
    (define-key map (kbd "X") 'monky-reset-tip)
    (define-key map (kbd "A") 'monky-addremove-all)
    (define-key map (kbd "L") 'monky-rollback)
    map))

(defvar monky-log-mode-map
  (let ((map (make-keymap)))
    (define-key map (kbd "e") 'monky-log-show-more-entries)
    (define-key map (kbd "C") 'monky-checkout-item)
    (define-key map (kbd "M") 'monky-merge-item)
    (define-key map (kbd "B") 'monky-backout-item)
    (define-key map (kbd "i") 'monky-qimport-item)
    map))

(defvar monky-blame-mode-map
  (let ((map (make-keymap)))
    map))

(defvar monky-branches-mode-map
  (let ((map (make-keymap)))
    (define-key map (kbd "C") 'monky-checkout-item)
    (define-key map (kbd "M") 'monky-merge-item)
    map))

(defvar monky-commit-mode-map
  (let ((map (make-keymap)))
    map))

(defvar monky-queue-mode-map
  (let ((map (make-keymap)))
    (define-key map (kbd "u") 'monky-qpop-item)
    (define-key map (kbd "U") 'monky-qpop-all)
    (define-key map (kbd "s") 'monky-qpush-item)
    (define-key map (kbd "S") 'monky-qpush-all)
    (define-key map (kbd "r") 'monky-qrefresh)
    (define-key map (kbd "R") 'monky-qrename-item)
    (define-key map (kbd "k") 'monky-qremove-item)
    (define-key map (kbd "N") 'monky-qnew)
    (define-key map (kbd "f") 'monky-qfinish-item)
    (define-key map (kbd "F") 'monky-qfinish-applied)
    (define-key map (kbd "d") 'monky-qfold-item)
    (define-key map (kbd "G") 'monky-qguard-item)
    (define-key map (kbd "o") 'monky-qreorder)
    (define-key map (kbd "A") 'monky-addremove-all)
    map))

(defvar monky-pre-log-edit-window-configuration nil)
(defvar monky-log-edit-client-buffer nil)
(defvar monky-log-edit-operation nil)
(defvar monky-log-edit-info nil)

(defvar monky-log-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") 'monky-log-edit-commit)
    (define-key map (kbd "C-c C-k") 'monky-log-edit-cancel-log-message)
    (define-key map (kbd "C-x C-s")
      (lambda ()
        (interactive)
        (message "Not saved. Use C-c C-c to finalize this %s." monky-log-edit-operation)))
    map))

;;; Sections

(defvar-local monky-top-section nil)
(defvar monky-old-top-section nil)
(defvar monky-section-hidden-default nil)

;; A buffer in monky-mode is organized into hierarchical sections.
;; These sections are used for navigation and for hiding parts of the
;; buffer.
;;
;; Most sections also represent the objects that Monky works with,
;; such as files, diffs, hunks, commits, etc.  The 'type' of a section
;; identifies what kind of object it represents (if any), and the
;; parent and grand-parent, etc provide the context.

(defstruct monky-section
  parent children beginning end type title hidden info)

(defun monky-set-section-info (info &optional section)
  (setf (monky-section-info (or section monky-top-section)) info))


(defun monky-new-section (title type)
  "Create a new section with title TITLE and type TYPE in current buffer.

If not `monky-top-section' exist, the new section will be the new top-section
otherwise, the new-section will be a child of the current top-section.

If TYPE is nil, the section won't be highlighted."
  (let* ((s (make-monky-section :parent monky-top-section
                                :title title
                                :type type
                                :hidden monky-section-hidden-default))
         (old (and monky-old-top-section
                   (monky-find-section (monky-section-path s)
                                       monky-old-top-section))))
    (if monky-top-section
        (push s (monky-section-children monky-top-section))
      (setq monky-top-section s))
    (if old
        (setf (monky-section-hidden s) (monky-section-hidden old)))
    s))

(defmacro monky-with-section (title type &rest body)
  "Create a new section of title TITLE and type TYPE and evaluate BODY there.

Sections create into BODY will be child of the new section.
BODY must leave point at the end of the created section.

If TYPE is nil, the section won't be highlighted."
  (declare (indent 2)
           (debug (symbolp symbolp body)))
  (let ((s (make-symbol "*section*")))
    `(let* ((,s (monky-new-section ,title ,type))
            (monky-top-section ,s))
       (setf (monky-section-beginning ,s) (point))
       ,@body
       (setf (monky-section-end ,s) (point))
       (setf (monky-section-children ,s)
             (nreverse (monky-section-children ,s)))
       ,s)))

(defmacro monky-create-buffer-sections (&rest body)
  "Empty current buffer of text and monky's section, and then evaluate BODY."
  (declare (indent 0)
           (debug (body)))
  `(let ((inhibit-read-only t))
     (erase-buffer)
     (let ((monky-old-top-section monky-top-section))
       (setq monky-top-section nil)
       ,@body
       (when (null monky-top-section)
         (monky-with-section 'top nil
           (insert "(empty)\n")))
       (monky-propertize-section monky-top-section)
       (monky-section-set-hidden monky-top-section
                                 (monky-section-hidden monky-top-section)))))

(defun monky-propertize-section (section)
  "Add text-property needed for SECTION."
  (put-text-property (monky-section-beginning section)
                     (monky-section-end section)
                     'monky-section section)
  (dolist (s (monky-section-children section))
    (monky-propertize-section s)))

(defun monky-find-section (path top)
  "Find the section at the path PATH in subsection of section TOP."
  (if (null path)
      top
    (let ((secs (monky-section-children top)))
      (while (and secs (not (equal (car path)
                                   (monky-section-title (car secs)))))
        (setq secs (cdr secs)))
      (and (car secs)
           (monky-find-section (cdr path) (car secs))))))

(defun monky-section-path (section)
  "Return the path of SECTION."
  (if (not (monky-section-parent section))
      '()
    (append (monky-section-path (monky-section-parent section))
            (list (monky-section-title section)))))

(defun monky-insert-section (section-title-and-type buffer-title washer cmd &rest args)
  "Run CMD and put its result in a new section.

SECTION-TITLE-AND-TYPE is either a string that is the title of the section
or (TITLE . TYPE) where TITLE is the title of the section and TYPE is its type.

If there is no type, or if type is nil, the section won't be highlighted.

BUFFER-TITLE is the inserted title of the section

WASHER is a function that will be run after CMD.
The buffer will be narrowed to the inserted text.
It should add sectioning as needed for monky interaction

CMD is an external command that will be run with ARGS as arguments"
  (monky-with-process
    (let* ((body-beg nil)
           (section-title (if (consp section-title-and-type)
                              (car section-title-and-type)
                            section-title-and-type))
           (section-type (if (consp section-title-and-type)
                             (cdr section-title-and-type)
                           nil))
           (section (monky-with-section section-title section-type
                      (if buffer-title
                          (insert (propertize buffer-title 'face 'monky-section-title) "\n"))
                      (setq body-beg (point))
                      (apply 'monky-process-file cmd nil t nil args)
                      (if (not (eq (char-before) ?\n))
                          (insert "\n"))
                      (if washer
                          (save-restriction
                            (narrow-to-region body-beg (point))
                            (goto-char (point-min))
                            (funcall washer)
                            (goto-char (point-max)))))))
      (when (= body-beg (point))
        (monky-cancel-section section))
      section)))

(defun monky-cancel-section (section)
  (delete-region (monky-section-beginning section)
                 (monky-section-end section))
  (let ((parent (monky-section-parent section)))
    (if parent
        (setf (monky-section-children parent)
              (delq section (monky-section-children parent)))
      (setq monky-top-section nil))))

(defun monky-current-section ()
  "Return the monky section at point."
  (monky-section-at (point)))

(defun monky-section-at (pos)
  "Return the monky section at position POS."
  (or (get-text-property pos 'monky-section)
      monky-top-section))

(defun monky-find-section-after (pos secs)
  "Find the first section that begins after POS in the list SECS."
  (while (and secs
              (not (> (monky-section-beginning (car secs)) pos)))
    (setq secs (cdr secs)))
  (car secs))

(defun monky-find-section-before (pos secs)
  "Find the last section that begins before POS in the list SECS."
  (let ((prev nil))
    (while (and secs
                (not (> (monky-section-beginning (car secs)) pos)))
      (setq prev (car secs))
      (setq secs (cdr secs)))
    prev))

(defun monky-next-section (section)
  "Return the section that is after SECTION."
  (let ((parent (monky-section-parent section)))
    (if parent
        (let ((next (cadr (memq section
                                (monky-section-children parent)))))
          (or next
              (monky-next-section parent))))))

(defvar-local monky-submode nil)
(defvar-local monky-refresh-function nil)
(defvar-local monky-refresh-args nil)

(defun monky-goto-next-section ()
  "Go to the next monky section."
  (interactive)
  (let* ((section (monky-current-section))
         (next (or (and (not (monky-section-hidden section))
                        (monky-section-children section)
                        (monky-find-section-after (point)
                                                  (monky-section-children
                                                   section)))
                   (monky-next-section section))))
    (cond
     ((and next (eq (monky-section-type next) 'longer))
      (when monky-log-auto-more
        (monky-log-show-more-entries)
        (monky-goto-next-section)))
     (next
      (goto-char (monky-section-beginning next))
      (if (memq monky-submode '(log blame))
          (monky-show-commit next)))
     (t (message "No next section")))))

(defun monky-prev-section (section)
  "Return the section that is before SECTION."
  (let ((parent (monky-section-parent section)))
    (if parent
        (let ((prev (cadr (memq section
                                (reverse (monky-section-children parent))))))
          (cond (prev
                 (while (and (not (monky-section-hidden prev))
                             (monky-section-children prev))
                   (setq prev (car (reverse (monky-section-children prev)))))
                 prev)
                (t
                 parent))))))


(defun monky-goto-previous-section ()
  "Goto the previous monky section."
  (interactive)
  (let ((section (monky-current-section)))
    (cond ((= (point) (monky-section-beginning section))
           (let ((prev (monky-prev-section (monky-current-section))))
             (if prev
                 (progn
                   (if (memq monky-submode '(log blame))
                       (monky-show-commit prev))
                   (goto-char (monky-section-beginning prev)))
               (message "No previous section"))))
          (t
           (let ((prev (monky-find-section-before (point)
                                                  (monky-section-children
                                                   section))))
             (if (memq monky-submode '(log blame))
                 (monky-show-commit (or prev section)))
             (goto-char (monky-section-beginning (or prev section))))))))


(defun monky-section-context-type (section)
  (if (null section)
      '()
    (let ((c (or (monky-section-type section)
                 (if (symbolp (monky-section-title section))
                     (monky-section-title section)))))
      (if c
          (cons c (monky-section-context-type
                   (monky-section-parent section)))
        '()))))

(defun monky-hg-section (section-title-and-type buffer-title washer &rest args)
  (apply #'monky-insert-section
         section-title-and-type
         buffer-title
         washer
         monky-hg-executable
         (append monky-hg-standard-options args)))

(defun monky-section-set-hidden (section hidden)
  "Hide SECTION if HIDDEN is not nil, show it otherwise."
  (setf (monky-section-hidden section) hidden)
  (let ((inhibit-read-only t)
        (beg (save-excursion
               (goto-char (monky-section-beginning section))
               (forward-line)
               (point)))
        (end (monky-section-end section)))
    (if (< beg end)
        (put-text-property beg end 'invisible hidden)))
  (if (not hidden)
      (dolist (c (monky-section-children section))
        (monky-section-set-hidden c (monky-section-hidden c)))))

(defun monky-toggle-section ()
  "Toggle hidden status of current section."
  (interactive)
  (let ((section (monky-current-section)))
    (when (monky-section-parent section)
      (goto-char (monky-section-beginning section))
      (monky-section-set-hidden section (not (monky-section-hidden section))))))

(defun monky-section-show-level-1-all ()
  "Collapse all the sections in the monky status buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (let ((section (monky-current-section)))
	(monky-section-set-hidden section t))
      (forward-line 1))))

(defun monky-section-show-level-2-all ()
  "Show all the files changes, but not their contents."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (let ((section (monky-current-section)))
	(if (memq (monky-section-type section) (list 'hunk 'diff))
	    (monky-section-set-hidden section t)
	  (monky-section-set-hidden section nil)))
      (forward-line 1))))

(defun monky-section-show-level-3-all ()
  "Expand all file contents and line numbers, but not the actual changes."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (let ((section (monky-current-section)))
	(if (memq (monky-section-type section) (list 'hunk))
	    (monky-section-set-hidden section t)
	  (monky-section-set-hidden section nil)))
      (forward-line 1))))

(defun monky-section-show-level-4-all ()
  "Expand all sections."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (let ((section (monky-current-section)))
	(monky-section-set-hidden section nil))
      (forward-line 1))))

;;; Running commands

(defun monky-set-mode-line-process (str)
  (let ((pr (if str (concat " " str) "")))
    (save-excursion
      (monky-for-all-buffers (lambda ()
                               (setq mode-line-process pr))))))

(defun monky-process-indicator-from-command (comps)
  (if (monky-prefix-p (cons monky-hg-executable monky-hg-standard-options)
                      comps)
      (setq comps (nthcdr (+ (length monky-hg-standard-options) 1) comps)))
  (car comps))

(defun monky-run* (cmd-and-args
		   &optional logline noerase noerror nowait input)
  (if (and monky-process
           (get-buffer monky-process-buffer-name))
      (error "Hg is already running"))
  (let ((cmd (car cmd-and-args))
        (args (cdr cmd-and-args))
        (dir default-directory)
        (buf (get-buffer-create monky-process-buffer-name))
        (successp nil))
    (monky-set-mode-line-process
     (monky-process-indicator-from-command cmd-and-args))
    (setq monky-process-client-buffer (current-buffer))
    (with-current-buffer buf
      (view-mode 1)
      (set (make-local-variable 'view-no-disable-on-exit) t)
      (setq view-exit-action
            (lambda (buffer)
              (with-current-buffer buffer
                (bury-buffer))))
      (setq buffer-read-only t)
      (let ((inhibit-read-only t))
        (setq default-directory dir)
        (if noerase
            (goto-char (point-max))
          (erase-buffer))
        (insert "$ " (or logline
                         (mapconcat #'identity cmd-and-args " "))
                "\n")
        (cond (nowait
               (setq monky-process
                     (let ((process-connection-type nil))
                       (apply 'monky-start-process cmd buf cmd args)))
               (set-process-sentinel monky-process 'monky-process-sentinel)
               (set-process-filter monky-process 'monky-process-filter)
               (when input
                 (with-current-buffer input
                   (process-send-region monky-process
                                        (point-min) (point-max))
                   (process-send-eof monky-process)
                   (sit-for 0.1 t)))
               (cond ((= monky-process-popup-time 0)
                      (pop-to-buffer (process-buffer monky-process)))
                     ((> monky-process-popup-time 0)
                      (run-with-timer
                       monky-process-popup-time nil
                       (function
                        (lambda (buf)
                          (with-current-buffer buf
                            (when monky-process
                              (display-buffer (process-buffer monky-process))
                              (goto-char (point-max))))))
                       (current-buffer))))
               (setq successp t))
	      (monky-cmd-process
	       (let ((monky-cmd-process-input-buffer input)
		     (monky-cmd-process-input-point (and input
						         (with-current-buffer input
						           (point-min)))))
		 (setq successp
		       (equal (apply #'monky-cmdserver-runcommand (cdr cmd-and-args)) 0))
		 (monky-set-mode-line-process nil)
		 (monky-need-refresh monky-process-client-buffer)))
              (input
               (with-current-buffer input
                 (setq default-directory dir)
                 (setq monky-process
                       ;; Don't use a pty, because it would set icrnl
                       ;; which would modify the input (issue #20).
                       (let ((process-connection-type nil))
                         (apply 'monky-start-process cmd buf cmd args)))
                 (set-process-filter monky-process 'monky-process-filter)
                 (process-send-region monky-process
                                      (point-min) (point-max))
                 (process-send-eof monky-process)
                 (while (equal (process-status monky-process) 'run)
                   (sit-for 0.1 t))
                 (setq successp
                       (equal (process-exit-status monky-process) 0))
                 (setq monky-process nil))
               (monky-set-mode-line-process nil)
               (monky-need-refresh monky-process-client-buffer))
              (t
               (setq successp
                     (equal (apply 'monky-process-file-single cmd nil buf nil args) 0))
               (monky-set-mode-line-process nil)
               (monky-need-refresh monky-process-client-buffer))))
      (or successp
          noerror
          (error
           (or monky-cmd-error-message
	       (monky-abort-message (get-buffer monky-process-buffer-name))
               "Hg failed")))
      successp)))


(defun monky-process-sentinel (process event)
  (let ((msg (format "Hg %s." (substring event 0 -1)))
        (successp (string-match "^finished" event)))
    (with-current-buffer (process-buffer process)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert msg "\n")
        (message msg)))
    (when (not successp)
      (let ((msg (monky-abort-message (process-buffer process))))
        (when msg
          (message msg))))
    (setq monky-process nil)
    (monky-set-mode-line-process nil)
    (if (buffer-live-p monky-process-client-buffer)
        (with-current-buffer monky-process-client-buffer
          (monky-with-refresh
            (monky-need-refresh monky-process-client-buffer))))))

(defun monky-abort-message (buffer)
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward
             (concat "^abort: \\(.*\\)" paragraph-separate) nil t)
        (match-string 1)))))

;; TODO password?

(defun monky-process-filter (proc string)
  (save-current-buffer
    (set-buffer (process-buffer proc))
    (let ((inhibit-read-only t))
      (goto-char (process-mark proc))
      (insert string)
      (set-marker (process-mark proc) (point)))))


(defun monky-run-hg (&rest args)
  (monky-with-refresh
    (monky-run* (append (cons monky-hg-executable
                              monky-hg-standard-options)
                        args))))

(defun monky-run-hg-sync (&rest args)
  (message "Running %s %s"
           monky-hg-executable
           (mapconcat #'identity args " "))
  (monky-run* (append (cons monky-hg-executable
			    monky-hg-standard-options)
		      args)))

(defun monky-run-hg-async (&rest args)
  (message "Running %s %s"
           monky-hg-executable
           (mapconcat #'identity args " "))
  (monky-run* (append (cons monky-hg-executable
                            monky-hg-standard-options)
                      args)
              nil nil nil t))

(defun monky-run-async-with-input (input cmd &rest args)
  (monky-run* (cons cmd args) nil nil nil t input))

(defun monky-display-process ()
  "Display output from most recent hg command."
  (interactive)
  (unless (get-buffer monky-process-buffer-name)
    (user-error "No Hg commands have run"))
  (display-buffer monky-process-buffer-name))

(defun monky-hg-command (command)
  "Perform arbitrary Hg COMMAND."
  (interactive "sRun hg like this: ")
  (let ((args (monky-parse-args command))
        (monky-process-popup-time 0))
    (monky-with-refresh
      (monky-run* (append (cons monky-hg-executable
                                monky-hg-standard-options)
                          args)
                  nil nil nil t))))

;;; Actions

(defmacro monky-section-case (opname &rest clauses)
  "Make different action depending of current section.

HEAD is (SECTION INFO &optional OPNAME),
  SECTION will be bind to the current section,
  INFO will be bind to the info's of the current section,
  OPNAME is a string that will be used to describe current action,

CLAUSES is a list of CLAUSE, each clause is (SECTION-TYPE &BODY)
where SECTION-TYPE describe section where BODY will be run.

This returns non-nil if some section matches.  If the
corresponding body return a non-nil value, it is returned,
otherwise it return t.

If no section matches, this returns nil if no OPNAME was given
and throws an error otherwise."

  (declare (indent 1)
           (debug (form &rest (sexp body))))
  (let ((section (make-symbol "*section*"))
        (type (make-symbol "*type*"))
        (context (make-symbol "*context*")))
    `(let* ((,section (monky-current-section))
            (,type (monky-section-type ,section))
            (,context (monky-section-context-type ,section)))
       (cond ,@(mapcar (lambda (clause)
                         (let ((prefix (car clause))
                               (body (cdr clause)))
                           `(,(if (eq prefix t)
                                  `t
                                `(monky-prefix-p ',(reverse prefix) ,context))
                             (or (progn ,@body)
                                 t))))
                       clauses)
             ,@(when opname
                 `(((not ,type)
                    (user-error "Nothing to %s here" ,opname))
                   (t
                    (error "Can't %s as %s"
                           ,opname
                           ,type))))))))

(defmacro monky-section-action (opname &rest clauses)
  "Refresh monky buffers after executing action defined in CLAUSES.

See `monky-section-case' for the definition of HEAD and CLAUSES and
`monky-with-refresh' for how the buffers are refreshed."
  (declare (indent 1)
           (debug (form &rest (sexp body))))
  `(monky-with-refresh
     (monky-section-case ,opname ,@clauses)))

(defun monky-visit-item (&optional other-window)
  "Visit current item.
With a prefix argument, visit in other window."
  (interactive (list current-prefix-arg))
  (let ((ff (if other-window 'find-file-other-window 'find-file)))
    (monky-section-action "visit"
      ((file)
       (funcall ff (monky-section-info (monky-current-section))))
      ((diff)
       (funcall ff (monky-diff-item-file (monky-current-section))))
      ((hunk)
       (let ((file (monky-diff-item-file (monky-hunk-item-diff (monky-current-section))))
             (line (monky-hunk-item-target-line (monky-current-section))))
         (funcall ff file)
         (goto-char (point-min))
         (forward-line (1- line))))
      ((commit)
       (monky-show-commit (monky-section-info (monky-current-section))))
      ((longer)
       (monky-log-show-more-entries))
      ((queue)
       (monky-qqueue (monky-section-info (monky-current-section))))
      ((branch)
       (monky-checkout (monky-section-info (monky-current-section))))
      ((shelf)
       (monky-show-shelf
	(monky-section-info (monky-current-section)))))))

(defun monky-ediff-item ()
  "Open the ediff merge editor on the item."
  (interactive)
  (monky-section-action "ediff"
    ((merged diff)
     (if (eq (monky-diff-item-kind (monky-current-section)) 'unresolved)
	 (monky-ediff-merged (monky-current-section))
       (user-error "Already resolved.  Unresolve first.")))
    ((unmodified diff)
     (user-error "Cannot ediff an unmodified file during a merge."))
    ((staged diff)
     (user-error "Already staged"))
    ((changes diff)
     (monky-ediff-changes (monky-current-section)))))

(defun monky-ediff-merged (item)
  (let* ((file (monky-diff-item-file item))
	 (file-path (concat (monky-get-root-dir) file)))
    (condition-case nil
	(monky-run-hg-sync "resolve" "--tool" "internal:dump" file)
      (error nil))
    (condition-case nil
	(ediff-merge-files-with-ancestor
	 (concat file-path ".local")
	 (concat file-path ".other")
	 (concat file-path ".base")
	 nil file)
      (error nil))
    (delete-file (concat file-path ".local"))
    (delete-file (concat file-path ".other"))
    (delete-file (concat file-path ".base"))
    (delete-file (concat file-path ".orig"))))

(defun monky-ediff-changes (item)
  (ediff-revision
   (concat (monky-get-root-dir)
	   (monky-diff-item-file item))))

(defvar monky-staged-all-files nil)
(defvar monky-old-staged-files '())
(defvar-local monky-staged-files nil)

(defun monky-stage-all ()
  "Add all items in Changes to the staging area."
  (interactive)
  (monky-with-refresh
    (setq monky-staged-all-files t)
    (monky-refresh-buffer)))

(defun monky-stage-item ()
  "Add the item at point to the staging area."
  (interactive)
  (monky-section-action "stage"
    ((untracked file)
     (monky-run-hg "add" (monky-section-info (monky-current-section))))
    ((untracked)
     (monky-run-hg "add"))
    ((missing file)
     (monky-run-hg "remove" "--after" (monky-section-info (monky-current-section))))
    ((changes diff)
     (monky-stage-file (monky-section-title (monky-current-section)))
     (monky-refresh-buffer))
    ((changes)
     (monky-stage-all))
    ((staged diff)
     (user-error "Already staged"))
    ((unmodified diff)
     (user-error "Cannot partially commit a merge"))
    ((merged diff)
     (user-error "Cannot partially commit a merge"))))

(defun monky-unstage-all ()
  "Remove all items from the staging area"
  (interactive)
  (monky-with-refresh
    (setq monky-staged-files '())
    (monky-refresh-buffer)))

(defun monky-unstage-item ()
  "Remove the item at point from the staging area."
  (interactive)
  (monky-with-process
    (monky-section-action "unstage"
      ((staged diff)
       (monky-unstage-file (monky-section-title (monky-current-section)))
       (monky-refresh-buffer))
      ((staged)
       (monky-unstage-all))
      ((changes diff)
       (user-error "Already unstaged")))))

;;; Updating

(defun monky-pull ()
  "Run hg pull. The monky-pull-args variable contains extra arguments to pass to hg."
  (interactive)
  (let ((remote (if current-prefix-arg
                    (monky-read-remote "Pull from : ")
                  monky-incoming-repository)))
    (apply #'monky-run-hg-async
	   "pull" (append monky-pull-args (list remote)))))

(defun monky-remotes ()
  (mapcar #'car (monky-hg-config-section "paths")))

(defun monky-read-remote (prompt)
  (monky-completing-read prompt
                         (monky-remotes)))

(defun monky-read-revision (prompt)
  (let ((revision (read-string prompt)))
    (unless (monky-hg-revision-p revision)
      (error "%s is not a revision" revision))
    revision))

(defun monky-push ()
  "Pushes current branch to the default path."
  (interactive)
  (let* ((branch (monky-current-branch))
         (remote (if current-prefix-arg
                     (monky-read-remote
                      (format "Push branch %s to : " branch))
                   monky-outgoing-repository)))
    (if (string= "" remote)
        (monky-run-hg-async "push" "--branch" branch)
      (monky-run-hg-async "push" "--branch" branch remote))))

(defun monky-checkout (node)
  (interactive (list (monky-read-revision "Update to: ")))
  (monky-run-hg "update" node))

(defun monky-merge (node)
  (interactive (list (monky-read-revision "Merge with: ")))
  (monky-run-hg "merge" node))

(defun monky-reset-tip ()
  (interactive)
  (when (yes-or-no-p "Discard all uncommitted changes? ")
    (monky-run-hg "update" "--clean")))

(defun monky-addremove-all ()
  (interactive)
  (monky-run-hg "addremove"))

(defun monky-rollback ()
  (interactive)
  (monky-run-hg "rollback"))

;;; Merging

(defun monky-unresolve-item ()
  "Mark the item at point as unresolved."
  (interactive)
  (monky-section-action "unresolve"
    ((merged diff)
     (if (eq (monky-diff-item-kind (monky-current-section)) 'resolved)
         (monky-run-hg "resolve" "--unmark" (monky-diff-item-file (monky-current-section)))
       (user-error "Already unresolved")))))

(defun monky-resolve-item ()
  "Mark the item at point as resolved."
  (interactive)
  (monky-section-action "resolve"
    ((merged diff)
     (if (eq (monky-diff-item-kind (monky-current-section)) 'unresolved)
         (monky-run-hg "resolve" "--mark" (monky-diff-item-file (monky-current-section)))
       (user-error "Already resolved")))))

;; History

(defun monky-backout (revision)
  "Runs hg backout."
  (interactive (list (monky-read-revision "Backout : ")))
  (monky-pop-to-log-edit 'backout revision))

(defun monky-backout-item ()
  "Backout the revision represented by current item."
  (interactive)
  (monky-section-action "backout"
    ((log commits commit)
     (monky-backout (monky-section-info (monky-current-section))))))

(defun monky-show-item-or-scroll-up ()
  (interactive)
  (monky-section-action "show"
    ((commit)
     (monky-show-commit (monky-section-info (monky-current-section)) nil #'scroll-up))
    (t
     (scroll-up))))

(defun monky-show-item-or-scroll-down ()
  (interactive)
  (monky-section-action "show"
    ((commit)
     (monky-show-commit (monky-section-info (monky-current-section)) nil #'scroll-down))
    (t
     (scroll-down))))

;;; Miscellaneous

(defun monky-revert-file (file)
  (when (or (not monky-revert-item-confirm)
	    (yes-or-no-p (format "Revert %s? " file)))
    (monky-run-hg "revert" "--no-backup" file)
    (let ((file-buf (find-buffer-visiting
		     (concat (monky-get-root-dir) file))))
      (if file-buf
	  (save-current-buffer
	    (set-buffer file-buf)
	    (revert-buffer t t t))))))

(defun monky-discard-item ()
  "Delete the file if not tracked, otherwise revert it."
  (interactive)
  (monky-section-action "discard"
    ((untracked file)
     (when (yes-or-no-p (format "Delete %s? " (monky-section-info (monky-current-section))))
       (delete-file (monky-section-info (monky-current-section)))
       (monky-refresh-buffer)))
    ((changes diff)
     (monky-revert-file (monky-diff-item-file (monky-current-section))))
    ((staged diff)
     (monky-revert-file (monky-diff-item-file (monky-current-section))))
    ((missing file)
     (monky-revert-file (monky-section-info (monky-current-section))))
    ((shelf)
     (monky-delete-shelf (monky-section-info (monky-current-section))))))

(defun monky-quit-window (&optional kill-buffer)
  "Bury the buffer and delete its window.  With a prefix argument, kill the
buffer instead."
  (interactive "P")
  (quit-window kill-buffer (selected-window)))

;;; Refresh

(defun monky-revert-buffers (dir &optional ignore-modtime)
  (dolist (buffer (buffer-list))
    (when (and buffer
               (buffer-file-name buffer)
               (monky-string-starts-with-p (buffer-file-name buffer) dir)
               (file-readable-p (buffer-file-name buffer))
               (or ignore-modtime (not (verify-visited-file-modtime buffer)))
               (not (buffer-modified-p buffer)))
      (with-current-buffer buffer
        (condition-case var
            (revert-buffer t t t)
          (error (let ((signal-data (cadr var)))
                   (cond (t (monky-bug-report signal-data))))))))))

(defvar monky-refresh-needing-buffers nil)
(defvar monky-refresh-pending nil)

(defun monky-refresh-wrapper (func)
  "A helper function for `monky-with-refresh'."
  (monky-with-process
    (if monky-refresh-pending
        (funcall func)
      (let* ((dir default-directory)
             (status-buffer (monky-find-status-buffer dir))
             (monky-refresh-needing-buffers nil)
             (monky-refresh-pending t))
        (unwind-protect
            (funcall func)
          (when monky-refresh-needing-buffers
            (monky-revert-buffers dir)
            (dolist (b (adjoin status-buffer
                               monky-refresh-needing-buffers))
              (monky-refresh-buffer b))))))))

(defun monky-need-refresh (&optional buffer)
  (let ((buffer (or buffer (current-buffer))))
    (setq monky-refresh-needing-buffers
          (adjoin buffer monky-refresh-needing-buffers))))

(defun monky-refresh ()
  "Refresh current buffer to match repository state.
Also revert every unmodified buffer visiting files
in the corresponding directory."
  (interactive)
  (monky-with-refresh
    (monky-need-refresh)))

(defun monky-refresh-buffer (&optional buffer)
  (with-current-buffer (or buffer (current-buffer))
    (let* ((old-line (line-number-at-pos))
           (old-section (monky-current-section))
           (old-path (and old-section
                          (monky-section-path old-section)))
           (section-line (and old-section
                              (count-lines
                               (monky-section-beginning old-section)
                               (point)))))
      (if monky-refresh-function
          (apply monky-refresh-function
                 monky-refresh-args))
      (let ((s (and old-path (monky-find-section old-path monky-top-section))))
        (cond (s
               (goto-char (monky-section-beginning s))
               (forward-line section-line))
              (t
               (monky-goto-line old-line)))
        (dolist (w (get-buffer-window-list (current-buffer)))
          (set-window-point w (point)))))))

(defvar monky-last-point nil)

(defun monky-remember-point ()
  (setq monky-last-point (point)))

(defun monky-invisible-region-end (pos)
  (while (and (not (= pos (point-max))) (invisible-p pos))
    (setq pos (next-char-property-change pos)))
  pos)

(defun monky-invisible-region-start (pos)
  (while (and (not (= pos (point-min))) (invisible-p pos))
    (setq pos (1- (previous-char-property-change pos))))
  pos)

(defun monky-correct-point-after-command ()
  "Move point outside of invisible regions.

Emacs often leaves point in invisible regions, it seems.  To fix
this, we move point ourselves and never let Emacs do its own
adjustments.

When point has to be moved out of an invisible region, it can be
moved to its end or its beginning.  We usually move it to its
end, except when that would move point back to where it was
before the last command."
  (if (invisible-p (point))
      (let ((end (monky-invisible-region-end (point))))
        (goto-char (if (= end monky-last-point)
                       (monky-invisible-region-start (point))
                     end))))
  (setq disable-point-adjustment t))

(defun monky-post-command-hook ()
  (monky-correct-point-after-command))

;;; Monky mode

(define-derived-mode monky-mode special-mode "Monky"
  "View the status of a mercurial repository.

\\{monky-mode-map}"
  (setq buffer-read-only t)
  (setq mode-line-process "")
  (setq truncate-lines t)
  (add-hook 'pre-command-hook #'monky-remember-point nil t)
  (add-hook 'post-command-hook #'monky-post-command-hook t t))

(defun monky-mode-init (dir submode refresh-func &rest refresh-args)
  (monky-mode)
  (setq default-directory dir
        monky-submode submode
        monky-refresh-function refresh-func
        monky-refresh-args refresh-args)
  (monky-refresh-buffer))


;;; Hg utils

(defmacro monky-with-temp-file (file &rest body)
  "Create a temporary file name, evaluate BODY and delete the file."
  (declare (indent 1)
           (debug (symbolp body)))
  `(let ((,file (make-temp-file "monky-temp-file")))
     (unwind-protect
         (progn ,@body)
       (delete-file ,file))))

(defun monky-hg-insert (args)
  (insert (monky-hg-output args)))

(defun monky-hg-output (args)
  (monky-with-temp-file stderr
    (save-current-buffer
      (with-temp-buffer
        (unless (eq 0 (apply #'monky-process-file
                             monky-hg-executable
                             nil (list t stderr) nil
                             (append monky-hg-standard-options args)))
          (error (with-temp-buffer
                   (insert-file-contents stderr)
                   (buffer-string))))
        (buffer-string)))))

(defun monky-hg-string (&rest args)
  (monky-trim-line (monky-hg-output args)))

(defun monky-hg-lines (&rest args)
  (monky-split-lines (monky-hg-output args)))

(defun monky-hg-exit-code (&rest args)
  (apply #'monky-process-file monky-hg-executable nil nil nil
         (append monky-hg-standard-options args)))

(defun monky-hg-revision-p (revision)
  (eq 0 (monky-hg-exit-code "identify" "--rev" revision)))

;; TODO needs cleanup
(defun monky-get-root-dir ()
  (if (and (featurep 'tramp)
	   (tramp-tramp-file-p default-directory))
      (monky-get-tramp-root-dir)
    (monky-get-local-root-dir)))

(defun monky-get-local-root-dir ()
  (let ((root (monky-hg-string "root")))
    (if root
	(concat root "/")
      (user-error "Not inside a hg repo"))))

(defun monky-get-tramp-root-dir ()
  (let ((root (monky-hg-string "root"))
        (tramp-path (vconcat (tramp-dissect-file-name default-directory))))
    (if root
        (progn (aset tramp-path 6 root)
               (concat (apply 'tramp-make-tramp-file-name (cdr (append tramp-path nil)))
                       "/"))
      (user-error "Not inside a hg repo"))))

(defun monky-find-buffer (submode &optional dir)
  (let ((rootdir (expand-file-name (or dir (monky-get-root-dir)))))
    (find-if (lambda (buf)
               (with-current-buffer buf
                 (and default-directory
                      (equal (expand-file-name default-directory) rootdir)
                      (eq major-mode 'monky-mode)
                      (eq monky-submode submode))))
             (buffer-list))))

(defun monky-find-status-buffer (&optional dir)
  (monky-find-buffer 'status dir))

(defun monky-for-all-buffers (func &optional dir)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (if (and (eq major-mode 'monky-mode)
               (or (null dir)
                   (equal default-directory dir)))
          (funcall func)))))

(defun monky-hg-config ()
  "Return an alist of ((section . key) . value)"
  (mapcar (lambda (line)
            (string-match "^\\([^.]*\\)\.\\([^=]*\\)=\\(.*\\)$" line)
            (cons (cons (match-string 1 line)
                        (match-string 2 line))
                  (match-string 3 line)))
          (monky-hg-lines "debugconfig")))

(defun monky-hg-config-section (section)
  "Return an alist of (name . value) for section"
  (mapcar (lambda (item)
            (cons (cdar item) (cdr item)))
          (remove-if-not (lambda (item)
                           (equal section (caar item)))
                         (monky-hg-config))))

(defvar monky-el-directory
  (file-name-directory (or load-file-name default-directory))
  "The parent directory of monky.el")

(defun monky-get-style-path (filename)
  (concat (file-name-as-directory (concat monky-el-directory "style"))
          filename))

(defvar monky-hg-style-log-graph
  (monky-get-style-path "log-graph"))

(defvar monky-hg-style-files-status
  (monky-get-style-path "files-status"))

(defvar monky-hg-style-tags
  (monky-get-style-path "tags"))

(defun monky-hg-log-tags (revision &rest args)
  (apply #'monky-hg-lines "log"
         "--style" monky-hg-style-tags
         "--rev" revision args))

(defun monky-qtip-p ()
  "Return non-nil if the current revision is qtip"
  (let ((rev (replace-regexp-in-string "\\+$" ""
                                       (monky-hg-string "identify" "--id"))))
    (let ((monky-cmd-process nil))      ; use single process
      (member "qtip" (monky-hg-log-tags rev "--config" "extensions.mq=")))))


;;; Washers

(defun monky-wash-status-lines (callback)
  "For every status line in the current buffer, remove it and call CALLBACK.
CALLBACK is called with the status and the associated filename."
  (while (and (not (eobp))
              (looking-at "\\([A-Z!? ]\\) \\([^\t\n]+\\)$"))
    (let ((status (case (string-to-char (match-string-no-properties 1))
                    (?M 'modified)
                    (?A 'new)
                    (?R 'removed)
                    (?C 'clean)
                    (?! 'missing)
                    (?? 'untracked)
                    (?I 'ignored)
                    (?U 'unresolved)
                    (t nil)))
          (file (match-string-no-properties 2)))
      (monky-delete-line t)
      (funcall callback status file))))

;; File

(defun monky-wash-files ()
  (let ((empty t))
    (monky-wash-status-lines
     (lambda (_status file)
       (setq empty nil)
       (monky-with-section file 'file
         (monky-set-section-info file)
         (insert file "\n"))))
    (unless empty
      (insert "\n"))))

;; Hunk

(defun monky-hunk-item-diff (hunk)
  (let ((diff (monky-section-parent hunk)))
    (or (eq (monky-section-type diff) 'diff)
        (error "Huh?  Parent of hunk not a diff"))
    diff))

(defun monky-hunk-item-target-line (hunk)
  (save-excursion
    (beginning-of-line)
    (let ((line (line-number-at-pos)))
      (goto-char (monky-section-beginning hunk))
      (if (not (looking-at "@@+ .* \\+\\([0-9]+\\),[0-9]+ @@+"))
          (error "Hunk header not found"))
      (let ((target (string-to-number (match-string 1))))
        (forward-line)
        (while (< (line-number-at-pos) line)
          ;; XXX - deal with combined diffs
          (if (not (looking-at "-"))
              (setq target (+ target 1)))
          (forward-line))
        target))))

(defun monky-wash-hunk ()
  (if (looking-at "\\(^@+\\)[^@]*@+")
      (let ((n-columns (1- (length (match-string 1))))
            (head (match-string 0)))
        (monky-with-section head 'hunk
          (add-text-properties (match-beginning 0) (1+ (match-end 0))
                               '(face monky-diff-hunk-header))
          (forward-line)
          (while (not (or (eobp)
                          (looking-at "^diff\\|^@@")))
            (let ((prefix (buffer-substring-no-properties
                           (point) (min (+ (point) n-columns) (point-max)))))
              (cond ((string-match "\\+" prefix)
                     (monky-put-line-property 'face 'monky-diff-add))
                    ((string-match "-" prefix)
                     (monky-put-line-property 'face 'monky-diff-del))
                    (t
                     (monky-put-line-property 'face 'monky-diff-none))))
            (forward-line))))
    nil))

;; Diff

(defvar monky-hide-diffs nil)

(defun monky-diff-item-kind (diff)
  (car (monky-section-info diff)))

(defun monky-diff-item-file (diff)
  (cadr (monky-section-info diff)))

(defun monky-diff-line-file ()
  (cond ((looking-at "^diff -r \\([^ ]*\\) \\(-r \\([^ ]*\\) \\)?\\(.*\\)$")
         (match-string-no-properties 4))
	((looking-at (rx "diff --git a/" (group (+? anything)) " b/"))
	 (match-string-no-properties 1))
        (t
         nil)))

(defun monky-wash-diff-section (&optional status file)
  (let ((case-fold-search nil))
   (cond ((looking-at "^diff ")
	  (let* ((file (monky-diff-line-file))
		 (end (save-excursion
		        (forward-line)
		        (if (search-forward-regexp "^diff \\|^@@" nil t)
			    (goto-char (match-beginning 0))
			  (goto-char (point-max)))
		        (point-marker)))
		 (status (or status
			     (cond
			      ((save-excursion
				 (search-forward-regexp "^--- /dev/null" end t))
			       'new)
			      ((save-excursion
				 (search-forward-regexp "^+++ /dev/null" end t))
			       'removed)
			      (t 'modified)))))
	    (monky-set-section-info (list status file))
	    (monky-insert-diff-title status file)
            ;; Remove the 'diff ...' text and '+++' text, as it's redundant.
            (delete-region (point) end)
	    (let ((monky-section-hidden-default nil))
	      (monky-wash-sequence #'monky-wash-hunk))))
	 ;; sometimes diff returns empty output
	 ((and status file)
	  (monky-set-section-info (list status file))
	  (monky-insert-diff-title status file))
	 (t nil))))

(defun monky-wash-diff ()
  (let ((monky-section-hidden-default monky-hide-diffs))
    (monky-with-section nil 'diff
      (monky-wash-diff-section))))

(defun monky-wash-diffs ()
  (monky-wash-sequence #'monky-wash-diff))

(defun monky-insert-diff (file &optional status cmd)
  (let ((p (point)))
    (monky-hg-insert (list (or cmd "diff") file))
    (if (not (eq (char-before) ?\n))
        (insert "\n"))
    (save-restriction
      (narrow-to-region p (point))
      (goto-char p)
      (monky-wash-diff-section status file)
      (goto-char (point-max)))))

(defun monky-insert-diff-title (status file)
  (insert
   (format "%-10s %s\n"
          (propertize
           (symbol-name status)
           'face
           (if (eq status 'unresolved) 'warning 'monky-diff-title))
          (propertize file 'face 'monky-diff-title))))

;;; Untracked files

(defun monky-insert-untracked-files ()
  (monky-hg-section 'untracked "Untracked files:" #'monky-wash-files
                    "status" "--unknown"))

;;; Missing files

(defun monky-insert-missing-files ()
  (monky-hg-section 'missing "Missing files:" #'monky-wash-files
                    "status" "--deleted"))

;;; Changes

(defun monky-wash-changes ()
  (let ((changes-p nil))
    (monky-wash-status-lines
     (lambda (status file)
       (let ((monky-section-hidden-default monky-hide-diffs))
         (if (or monky-staged-all-files
                 (member file monky-old-staged-files))
             (monky-stage-file file)
           (monky-with-section file 'diff
             (monky-insert-diff file status))
           (setq changes-p t)))))
    (when changes-p
      (insert "\n"))))


(defun monky-insert-changes ()
  (let ((monky-hide-diffs t))
    (setq monky-old-staged-files (copy-list monky-staged-files))
    (setq monky-staged-files '())
    (monky-hg-section 'changes "Changes:" #'monky-wash-changes
                      "status" "--modified" "--added" "--removed")))

;; Staged Changes

(defun monky-stage-file (file)
  (if (not (member file monky-staged-files))
      (setq monky-staged-files (cons file monky-staged-files))))

(defun monky-unstage-file (file)
  (setq monky-staged-files (delete file monky-staged-files)))

(defun monky-insert-staged-changes ()
  (when monky-staged-files
    (monky-with-section 'staged nil
      (insert (propertize "Staged changes:" 'face 'monky-section-title) "\n")
      (let ((monky-section-hidden-default t))
        (dolist (file monky-staged-files)
          (monky-with-section file 'diff
            (monky-insert-diff file)))))
    (insert "\n"))
  (setq monky-staged-all-files nil))

;;; Shelves

(defun monky-extensions ()
  "Return a list of all the enabled mercurial extensions."
  (let* ((config
          (string-trim (shell-command-to-string "hg config extensions")))
         (lines
          (split-string config "\n"))
         extensions)
    (dolist (line lines)
      (unless (string-match-p (rx "!" eos) line)
        (setq line (string-remove-prefix "extensions." line))
        (setq line (string-remove-suffix "=" line)))
      (push line extensions))
    (nreverse extensions)))

(defun monky-insert-shelves ()
  (when (member "shelve" (monky-extensions))
    (monky-hg-section 'shelves "Shelves:" #'monky-wash-shelves
                      "shelve" "--list")))

(defun monky-wash-shelves ()
  "Set shelf names on each line.
This is naive and assumes that shelf names never contain (."
  (while (re-search-forward
          (rx bol (group (+? not-newline))
              (+ space) "(")
          nil
          t)
    (goto-char (line-beginning-position))
    (monky-with-section 'shelf nil
      (monky-set-section-info (match-string 1))
      (put-text-property
       (match-beginning 1)
       (match-end 1)
       'face
       'monky-commit-id)
      (goto-char (line-end-position)))))

;;; Parents

(defvar-local monky-parents nil)

(defun monky-merge-p ()
  (> (length monky-parents) 1))

(defun monky-wash-parent ()
  (if (looking-at "changeset:\s*\\([0-9]+\\):\\([0-9a-z]+\\)")
      (let ((changeset (match-string 2))
	    (line (buffer-substring (line-beginning-position) (line-end-position))))
        (push changeset monky-parents)

	;; Remove the plain text 'changeset: ...' and replace it with
	;; propertized text, plus a section that knows the changeset
	;; (so RET shows the full commit).
	(monky-with-section 'commit nil
	  (monky-set-section-info changeset)
	  (monky-delete-line t)
	  (insert line "\n")

	  (put-text-property
           (match-beginning 1)
           (match-end 1)
           'face
           'monky-commit-id)
          (put-text-property
           (match-beginning 2)
           (match-end 2)
           'face
           'monky-commit-id))

        (while (not (or (eobp)
                        (looking-at "changeset:\s*\\([0-9]+\\):\\([0-9a-z]+\\)")))
          (forward-line))
        t)
    nil))

(defun monky-wash-parents ()
  (monky-wash-sequence #'monky-wash-parent))

(defun monky-insert-parents ()
  (monky-hg-section 'parents "Parents:"
                    #'monky-wash-parents "parents"))

;;; Merged Files

(defvar-local monky-merged-files nil)

(defun monky-wash-merged-files ()
  (let ((empty t))
    (monky-wash-status-lines
     (lambda (status file)
       (setq empty nil)
       (let ((monky-section-hidden-default monky-hide-diffs))
        (push file monky-merged-files)
        ;; XXX hg uses R for resolved and removed status
        (let ((status (if (eq status 'unresolved)
                           'unresolved
                        'resolved)))
           (monky-with-section file 'diff
             (monky-insert-diff file status))))))
    (unless empty
      (insert "\n"))))

(defun monky-insert-merged-files ()
  (let ((monky-hide-diffs t))
    (setq monky-merged-files '())
    (monky-hg-section 'merged "Merged Files:" #'monky-wash-merged-files
                      "resolve" "--list")))

;;; Unmodified Files

(defun monky-wash-unmodified-files ()
  (monky-wash-status-lines
   (lambda (_status file)
     (let ((monky-section-hidden-default monky-hide-diffs))
       (when (not (member file monky-merged-files))
         (monky-with-section file 'diff
           (monky-insert-diff file)))))))

(defun monky-insert-resolved-files ()
  (let ((monky-hide-diffs t))
    (monky-hg-section 'unmodified "Unmodified files during merge:" #'monky-wash-unmodified-files
                      "status" "--modified" "--added" "--removed")))
;;; Status mode

(defun monky-refresh-status ()
  (setq monky-parents nil
        monky-merged-files nil)
  (monky-create-buffer-sections
    (monky-with-section 'status nil
      (monky-insert-parents)
      (if (monky-merge-p)
          (progn
            (monky-insert-merged-files)
            (monky-insert-resolved-files))
        (monky-insert-untracked-files)
        (monky-insert-missing-files)
        (monky-insert-changes)
        (monky-insert-staged-changes)
        (monky-insert-shelves)))))

(define-minor-mode monky-status-mode
  "Minor mode for hg status.

\\{monky-status-mode-map}"
  :group monky
  :init-value ()
  :lighter ()
  :keymap monky-status-mode-map)

;;;###autoload
(defun monky-status (&optional directory)
  "Show the status of Hg repository."
  (interactive)
  (monky-with-process
    (let* ((rootdir (or directory (monky-get-root-dir)))
           (buf (or (monky-find-status-buffer rootdir)
                    (generate-new-buffer
                     (concat "*monky: "
                             (file-name-nondirectory
                              (directory-file-name rootdir)) "*")))))
      (pop-to-buffer buf)
      (monky-mode-init rootdir 'status #'monky-refresh-status)
      (monky-status-mode t))))

;;; Log mode

(define-minor-mode monky-log-mode
  "Minor mode for hg log.

\\{monky-log-mode-map}"
  :group monky
  :init-value ()
  :lighter ()
  :keymap monky-log-mode-map)

(defvar monky-log-buffer-name "*monky-log*")

(defun monky-propertize-labels (label-list &rest properties)
  "Propertize labels (tag/branch/bookmark/...) in LABEL-LIST.

PROPERTIES is the arguments for the function `propertize'."
  (apply #'concat
         (apply #'append
                (mapcar (lambda (l)
                          (unless (or (string= l "") (string= l "None"))
                            (list (apply #'propertize l properties) " ")))
                        label-list))))

(defun monky-present-log-line (width graph id branches tags bookmarks phase author date message)
  (let* ((hg-info (concat
                   (propertize (substring id 0 8) 'face 'monky-log-sha1)
                   " "
                   graph
                   (monky-propertize-labels branches 'face 'monky-log-head-label-local)
                   (monky-propertize-labels tags 'face 'monky-log-head-label-tags)
                   (monky-propertize-labels bookmarks 'face 'monky-log-head-label-bookmarks)
                   (unless (or (string= phase "") (string= phase "public"))
                     (monky-propertize-labels `(,phase) 'face 'monky-log-head-label-phase))))
         (total-space-left (max 0 (- width (length hg-info))))
         (author-date-space-taken (+ 16 (min 10 (length author))))
         (message-space-left (number-to-string (max 0 (- total-space-left author-date-space-taken 1))))
         (msg-format (concat "%-" message-space-left "." message-space-left "s"))
         (msg (format msg-format message)))
    (let* ((shortened-msg (if (< 3 (length msg))
                              (concat (substring msg 0 -3) "...")
                            msg))
           (msg (if (>= (string-to-number message-space-left) (length message))
                   msg
                  shortened-msg)))
      (concat
       hg-info
       (propertize msg 'face 'monky-log-message)
       (propertize (format " %.10s" author) 'face 'monky-log-author)
       (propertize (format " %.10s" date) 'face 'monky-log-date)))))

(defun monky-log-current-branch ()
  (interactive)
  (monky-log "ancestors(.)"))

(defun monky-log-buffer-file ()
  "View a log of commits that affected the current file."
  (interactive)
  (monky-log "ancestors(.)" (buffer-file-name)))

(defun monky-log-all ()
  (interactive)
  (monky-log nil))

(defun monky-log-revset (revset)
  (interactive  "sRevset: ")
  (monky-log revset))

(defun monky-log (revs &optional path)
  (monky-with-process
    (let ((topdir (monky-get-root-dir)))
      (pop-to-buffer monky-log-buffer-name)
      (setq default-directory topdir
            monky-root-dir topdir)
      (monky-mode-init topdir 'log (monky-refresh-log-buffer revs path))
      (monky-log-mode t))))

(defvar monky-log-graph-re
  (concat
   "^\\([-_\\/@o+|\s]+\s*\\) "          ; 1. graph
   "\\([a-z0-9]\\{40\\}\\) "            ; 2. id
   "<branches>\\(.?*\\)</branches>"     ; 3. branches
   "<tags>\\(.?*\\)</tags>"             ; 4. tags
   "<bookmarks>\\(.?*\\)</bookmarks>"   ; 5. bookmarks
   "<phase>\\(.?*\\)</phase>"           ; 6. phase
   "<author>\\(.*?\\)</author>"         ; 7. author
   "<monky-date>\\([0-9]+\\).?*</monky-date>" ; 8. date
   "\\(.*\\)$"                          ; 9. msg
   ))

(defun monky-decode-xml-entities (str)
  (setq str (replace-regexp-in-string "&lt;" "<" str))
  (setq str (replace-regexp-in-string "&gt;" ">" str))
  (setq str (replace-regexp-in-string "&amp;" "&" str))
  str)

(defun monky-xml-items-to-list (xml-like tag)
  "Convert XML-LIKE string which has repeated TAG items into a list of strings.

Example:
    (monky-xml-items-to-list \"<tag>A</tag><tag>B</tag>\" \"tag\")
    ; => (\"A\" \"B\")
"
  (mapcar #'monky-decode-xml-entities
          (split-string (replace-regexp-in-string
                         (format "^<%s>\\|</%s>$" tag tag) "" xml-like)
                        (format "</%s><%s>" tag tag))))

(defvar monky-log-count ()
  "Internal var used to count the number of logs actually added in a buffer.")

(defun monky--author-name (s)
  "Extract the name from a Mercurial author string."
  (save-match-data
    (cond
     ((string-match
       ;; If S contains a space, take the first word.
       (rx (group (1+ (not space)))
           space)
       s)
      (match-string 1 s))
     ((string-match
       ;; If S is just an email, take the username.
       (rx (group (1+ (not (any "@"))))
           "@")
       s)
      (match-string 1 s))
     (t s))))

(defun monky-wash-log-line ()
  (if (looking-at monky-log-graph-re)
      (let ((width (window-total-width))
            (graph (match-string 1))
            (id (match-string 2))
            (branches (match-string 3))
            (tags (match-string 4))
            (bookmarks (match-string 5))
            (phase (match-string 6))
            (author (monky--author-name (match-string 7)))
            (date (format-time-string "%Y-%m-%d" (seconds-to-time (string-to-number (match-string 8)))))
            (msg (match-string 9)))
        (monky-delete-line)
        (monky-with-section id 'commit
          (insert (monky-present-log-line
                   width
                   graph id
                   (monky-xml-items-to-list branches "branch")
                   (monky-xml-items-to-list tags "tag")
                   (monky-xml-items-to-list bookmarks "bookmark")
                   (monky-decode-xml-entities phase)
                   (monky-decode-xml-entities author)
                   (monky-decode-xml-entities date)
                   (monky-decode-xml-entities msg)))
          (monky-set-section-info id)
          (when monky-log-count (incf monky-log-count))
          (forward-line)
          (when (looking-at "^\\([\\/@o+-|\s]+\s*\\)$")
            (let ((graph (match-string 1)))
              (insert "         ")
              (forward-line))))
        t)
    nil))

(defun monky-wash-logs ()
  (let ((monky-old-top-section nil))
    (monky-wash-sequence #'monky-wash-log-line)))

(defmacro monky-create-log-buffer-sections (&rest body)
  "Empty current buffer of text and monky's section, and then evaluate BODY.

if the number of logs inserted in the buffer is `monky-log-cutoff-length'
insert a line to tell how to insert more of them"
  (declare (indent 0)
           (debug (body)))
  `(let ((monky-log-count 0))
     (monky-create-buffer-sections
       (monky-with-section 'log nil
         ,@body
         (if (= monky-log-count monky-log-cutoff-length)
           (monky-with-section "longer"  'longer
             (insert "type \"e\" to show more logs\n")))))))

(defun monky-log-show-more-entries (&optional arg)
  "Grow the number of log entries shown.

With no prefix optional ARG, show twice as much log entries.
With a numerical prefix ARG, add this number to the number of shown log entries.
With a non numeric prefix ARG, show all entries"
  (interactive "P")
  (make-local-variable 'monky-log-cutoff-length)
  (cond
   ((numberp arg)
    (setq monky-log-cutoff-length (+ monky-log-cutoff-length arg)))
   (arg
    (setq monky-log-cutoff-length monky-log-infinite-length))
   (t (setq monky-log-cutoff-length (* monky-log-cutoff-length 2))))
  (monky-refresh))

(defun monky-refresh-log-buffer (revs path)
  (lambda ()
    (monky-create-log-buffer-sections
      (monky-hg-section
       'commits
       (if path
	   (format "Commits affecting %s:"
		   (file-relative-name path monky-root-dir))
	 "Commits:")
       #'monky-wash-logs
       "log"
       "--config" "extensions.graphlog="
       "-G"
       "--limit" (number-to-string monky-log-cutoff-length)
       "--style" monky-hg-style-log-graph
       (if revs "--rev" "")
       (if revs revs "")
       (if path path "")))))

(defun monky-next-sha1 (pos)
  "Return position of next sha1 after given position POS"
  (while (and pos
              (not (equal (get-text-property pos 'face) 'monky-log-sha1)))
    (setq pos (next-single-property-change pos 'face)))
  pos)

(defun monky-previous-sha1 (pos)
  "Return position of previous sha1 before given position POS"
  (while (and pos
              (not (equal (get-text-property pos 'face) 'monky-log-sha1)))
    (setq pos (previous-single-property-change pos 'face)))
  pos)

;;; Blame mode
(define-minor-mode monky-blame-mode
  "Minor mode for hg blame.

\\{monky-blame-mode-map}"
  :group monky
  :init-value ()
  :lighter ()
  :keymap monky-blame-mode-map)

(defun monky-present-blame-line (author changeset text)
  (concat author
	  " "
	  (propertize changeset 'face 'monky-log-sha1)
	  ": "
	  text))

(defvar monky-blame-re
  (concat
   "\\(.*\\) "               ; author
   "\\([a-f0-9]\\{12\\}\\):" ; changeset
   "\\(.*\\)$"               ; text
   ))

(defun monky-wash-blame-line ()
  (if (looking-at monky-blame-re)
      (let ((author (match-string 1))
	    (changeset (match-string 2))
	    (text (match-string 3)))
	(monky-delete-line)
	(monky-with-section changeset 'commit
	  (insert (monky-present-blame-line author changeset text))
	  (monky-set-section-info changeset)
	  (forward-line))
	t)))

(defun monky-wash-blame ()
  (monky-wash-sequence #'monky-wash-blame-line))

(defun monky-refresh-blame-buffer (file-name)
  (monky-create-buffer-sections
    (monky-with-section file-name 'blame
      (monky-hg-section nil nil
			#'monky-wash-blame
			"blame"
			"--user"
			"--changeset"
			file-name))))

(defun monky-blame-current-file ()
  (interactive)
  (monky-with-process
    (let ((file-name (buffer-file-name))
	  (topdir (monky-get-root-dir))
          (line-num (line-number-at-pos))
          (column (current-column)))
      (pop-to-buffer
       (format "*monky-blame: %s*"
               (file-name-nondirectory buffer-file-name)))
      (monky-mode-init topdir 'blame #'monky-refresh-blame-buffer file-name)
      (monky-blame-mode t)
      ;; Put point on the same line number as the original file.
      (forward-line (1- line-num))
      (while (and (not (looking-at ":")) (not (eolp)))
        (forward-char))
      ;; Step over the blame information columns.
      (forward-char (length ":  "))
      ;; Put point at the same column as the original file.
      (forward-char column))))

;;; Commit mode

(define-minor-mode monky-commit-mode
  "Minor mode to view a hg commit.

\\{monky-commit-mode-map}"

  :group monky
  :init-value ()
  :lighter ()
  :keymap monky-commit-mode-map)

(defvar monky-commit-buffer-name "*monky-commit*")

(defun monky-empty-buffer-p (buffer)
  (with-current-buffer buffer
    (< (length (buffer-string)) 1)))

(defun monky-show-commit (commit &optional select scroll)
  (monky-with-process
    (when (monky-section-p commit)
      (setq commit (monky-section-info commit)))
    (unless (and commit
                 (monky-hg-revision-p commit))
      (error "%s is not a commit" commit))
    (let ((topdir (monky-get-root-dir))
          (buffer (get-buffer-create monky-commit-buffer-name)))
      (cond
       ((and scroll
	     (not (monky-empty-buffer-p buffer)))
        (let ((win (get-buffer-window buffer)))
          (cond ((not win)
                 (display-buffer buffer))
                (t
                 (with-selected-window win
                   (funcall scroll))))))
       (t
        (display-buffer buffer)
        (with-current-buffer buffer
          (monky-mode-init topdir 'commit
                           #'monky-refresh-commit-buffer commit)
          (monky-commit-mode t))))
      (if select
          (pop-to-buffer buffer)))))

(defun monky-show-shelf (name)
  (let ((buffer (get-buffer-create "*monky-shelf*"))
        (inhibit-read-only t))
    (pop-to-buffer buffer)

    (erase-buffer)
    (monky-hg-section
     nil nil
     #'ignore
     "shelve" "-l" "-p" name)
    (goto-char (point-min))
    (when (re-search-forward "^diff " nil t)
      (goto-char (line-beginning-position))
      (monky-wash-diffs))
    (monky-mode)))

(defun monky-delete-shelf (name)
  (unless (zerop (monky-hg-exit-code "shelve" "--delete" name))
    (user-error "Could not drop shelved %s" name))
  (monky-refresh-buffer))

(defun monky-refresh-commit-buffer (commit)
  (monky-create-buffer-sections
    (monky-hg-section nil nil
                      #'monky-wash-commit
                      "-v"
                      "log"
                      "--stat"
                      "--patch"
                      "--rev" commit)))

(defun monky-wash-commit ()
  (save-excursion
    (monky-wash-parent))
  (let ((case-fold-search nil))
   (while (and (not (eobp)) (not (looking-at "^diff ")) )
     (forward-line))
   (when (looking-at "^diff ")
     (monky-wash-diffs))))

;;; Branch mode
(define-minor-mode monky-branches-mode
  "Minor mode for hg branch.

\\{monky-branches-mode-map}"
  :group monky
  :init-value ()
  :lighter ()
  :keymap monky-branches-mode-map)

(defvar monky-branches-buffer-name "*monky-branches*")

(defvar monky-branch-re "^\\(.*[^\s]\\)\s* \\([0-9]+\\):\\([0-9a-z]\\{12\\}\\)\\(.*\\)$")

(defvar-local monky-current-branch-name nil)

(defun monky-present-branch-line (name rev node status)
  (concat rev " : "
          (propertize node 'face 'monky-log-sha1) " "
          (if (equal name monky-current-branch-name)
              (propertize name 'face 'monky-branch)
            name)
          " "
          status))

(defun monky-wash-branch-line ()
  (if (looking-at monky-branch-re)
      (let ((name (match-string 1))
            (rev (match-string 2))
            (node (match-string 3))
            (status (match-string 4)))
        (monky-delete-line)
        (monky-with-section name 'branch
          (insert (monky-present-branch-line name rev node status))
          (monky-set-section-info node)
          (forward-line))
        t)
    nil))

(defun monky-wash-branches ()
  (monky-wash-sequence #'monky-wash-branch-line))

(defun monky-refresh-branches-buffer ()
  (setq monky-current-branch-name (monky-current-branch))
  (monky-create-buffer-sections
    (monky-with-section 'buffer nil
      (monky-hg-section nil "Branches:"
                        #'monky-wash-branches
                        "branches"))))

(defun monky-current-branch ()
  (monky-hg-string "branch"))

(defun monky-branches ()
  (interactive)
  (let ((topdir (monky-get-root-dir)))
    (pop-to-buffer monky-branches-buffer-name)
    (monky-mode-init topdir 'branches #'monky-refresh-branches-buffer)
    (monky-branches-mode t)))

(defun monky-checkout-item ()
  "Checkout the revision represented by current item."
  (interactive)
  (monky-section-action "checkout"
    ((branch)
     (monky-checkout (monky-section-info (monky-current-section))))
    ((log commits commit)
     (monky-checkout (monky-section-info (monky-current-section))))))

(defun monky-merge-item ()
  "Merge the revision represented by current item."
  (interactive)
  (monky-section-action "merge"
    ((branch)
     (monky-merge (monky-section-info (monky-current-section))))
    ((log commits commit)
     (monky-merge (monky-section-info (monky-current-section))))))

;;; Queue mode
(define-minor-mode monky-queue-mode
  "Minor mode for hg Queue.

\\{monky-queue-mode-map}"
  :group monky
  :init-value ()
  :lighter ()
  :keymap monky-queue-mode-map)

(defvar monky-queue-buffer-name "*monky-queue*")

(defvar-local monky-patches-dir ".hg/patches/")

(defun monky-patch-series-file ()
  (concat monky-patches-dir "series"))

(defun monky-insert-patch (patch inserter &rest args)
  (let ((p (point))
        (monky-hide-diffs nil))
    (save-restriction
      (narrow-to-region p p)
      (apply inserter args)
      (goto-char (point-max))
      (if (not (eq (char-before) ?\n))
          (insert "\n"))
      (goto-char p)
      (while (and (not (eobp)) (not (looking-at "^diff")))
        (monky-delete-line t))
      (when (looking-at "^diff")
        (monky-wash-diffs))
      (goto-char (point-max)))))

(defun monky-insert-guards (patch)
  (let ((guards (remove-if
                 (lambda (guard) (string= "unguarded" guard))
                 (split-string
                  (cadr (split-string
                         (monky-hg-string "qguard" patch
                                          "--config" "extensions.mq=")
                         ":"))))))
    (dolist (guard guards)
      (insert (propertize " " 'face 'monky-queue-patch)
              (propertize guard
                          'face
                          (if (monky-string-starts-with-p guard "+")
                              'monky-queue-positive-guard
                            'monky-queue-negative-guard))))
    (insert (propertize "\n" 'face 'monky-queue-patch))))

(defun monky-wash-queue-patch ()
  (monky-wash-queue-insert-patch #'insert-file-contents))

(defvar monky-queue-staged-all-files nil)
(defvar-local monky-queue-staged-files nil)
(defvar-local monky-queue-old-staged-files nil)

(defun monky-wash-queue-discarding ()
  (monky-wash-status-lines
   (lambda (status file)
     (let ((monky-section-hidden-default monky-hide-diffs))
       (if (or monky-queue-staged-all-files
               (member file monky-old-staged-files)
               (member file monky-queue-old-staged-files))
           (monky-queue-stage-file file)
         (monky-with-section file 'diff
           (monky-insert-diff file status "qdiff"))))))
  (setq monky-queue-staged-all-files nil))

(defun monky-wash-queue-insert-patch (inserter)
  (if (looking-at "^\\([^\n]+\\)$")
      (let ((patch (match-string 1)))
        (monky-delete-line)
        (let ((monky-section-hidden-default t))
          (monky-with-section patch 'patch
            (monky-set-section-info patch)
            (insert
             (propertize (format "\t%s" patch) 'face 'monky-queue-patch))
            (monky-insert-guards patch)
            (funcall #'monky-insert-patch
                     patch inserter (concat monky-patches-dir patch))
            (forward-line)))
        t)
    nil))

(defun monky-wash-queue-queue ()
  (if (looking-at "^\\([^()\n]+\\)\\(\\s-+([^)]*)\\)?$")
      (let ((queue (match-string 1)))
        (monky-delete-line)
        (when (match-beginning 2)
          (setq monky-patches-dir
                (if (string= queue "patches")
                    ".hg/patches/"
                  (concat ".hg/patches-" queue "/")))
          (put-text-property 0 (length queue) 'face 'monky-queue-active queue))
        (monky-with-section queue 'queue
          (monky-set-section-info queue)
          (insert "\t" queue)
          (forward-line))
        t)
    nil))

(defun monky-wash-queue-queues ()
    (if (looking-at "^patches (.*)\n?\\'")
        (progn
          (monky-delete-line t)
          nil)
      (monky-wash-sequence #'monky-wash-queue-queue)))

(defun monky-wash-queue-patches ()
  (monky-wash-sequence #'monky-wash-queue-patch))

;;; Queues
(defun monky-insert-queue-queues ()
  (monky-hg-section 'queues "Patch Queues:"
                    #'monky-wash-queue-queues
                    "qqueue" "--list" "extensions.mq="))

;;; Applied Patches
(defun monky-insert-queue-applied ()
  (monky-hg-section 'applied "Applied Patches:" #'monky-wash-queue-patches
                    "qapplied" "--config" "extensions.mq="))

;;; UnApplied Patches
(defun monky-insert-queue-unapplied ()
  (monky-hg-section 'unapplied "UnApplied Patches:" #'monky-wash-queue-patches
                    "qunapplied" "--config" "extensions.mq="))

;;; Series
(defun monky-insert-queue-series ()
  (monky-hg-section 'qseries "Series:" #'monky-wash-queue-patches
                    "qseries" "--config" "extensions.mq="))

;;; Qdiff
(defun monky-insert-queue-discarding ()
  (when (monky-qtip-p)
    (setq monky-queue-old-staged-files (copy-list monky-queue-staged-files))
    (setq monky-queue-staged-files '())
    (let ((monky-hide-diffs t))
      (monky-hg-section 'discarding "Discarding (qdiff):"
                        #'monky-wash-queue-discarding
                        "log" "--style" monky-hg-style-files-status
                        "--rev" "qtip"))))

(defun monky-insert-queue-staged-changes ()
  (when (and (monky-qtip-p)
             (or monky-queue-staged-files monky-staged-files))
    (monky-with-section 'queue-staged nil
      (insert (propertize "Staged changes (qdiff):"
                          'face 'monky-section-title) "\n")
      (let ((monky-section-hidden-default t))
        (dolist (file (delete-dups (copy-list (append monky-queue-staged-files
                                                      monky-staged-files))))
          (monky-with-section file 'diff
            (monky-insert-diff file nil "qdiff")))))
    (insert "\n")))

(defun monky-wash-active-guards ()
  (if (looking-at "^no active guards")
      (monky-delete-line t)
    (monky-wash-sequence
     (lambda ()
       (let ((guard (buffer-substring (point) (point-at-eol))))
         (monky-delete-line)
         (insert " " (propertize guard 'face 'monky-queue-positive-guard))
         (forward-line))))))


;;; Active guards
(defun monky-insert-active-guards ()
  (monky-hg-section 'active-guards "Active Guards:" #'monky-wash-active-guards
                    "qselect" "--config" "extensions.mq="))

;;; Queue Staged Changes

(defun monky-queue-stage-file (file)
  (push file monky-queue-staged-files))

(defun monky-queue-unstage-file (file)
  (setq monky-queue-staged-files (delete file monky-queue-staged-files)))

(defun monky-refresh-queue-buffer ()
  (monky-create-buffer-sections
    (monky-with-section 'queue nil
      (monky-insert-untracked-files)
      (monky-insert-missing-files)
      (monky-insert-changes)
      (monky-insert-staged-changes)
      (monky-insert-queue-discarding)
      (monky-insert-queue-staged-changes)
      (monky-insert-queue-queues)
      (monky-insert-active-guards)
      (monky-insert-queue-applied)
      (monky-insert-queue-unapplied)
      (monky-insert-queue-series))))

(defun monky-queue ()
  (interactive)
  (monky-with-process
    (let ((topdir (monky-get-root-dir)))
      (pop-to-buffer monky-queue-buffer-name)
      (monky-mode-init topdir 'queue #'monky-refresh-queue-buffer)
      (monky-queue-mode t))))

(defun monky-qqueue (queue)
  (monky-run-hg "qqueue"
                "--config" "extensions.mq="
                queue))

(defun monky-qpop (&optional patch)
  (interactive)
  (apply #'monky-run-hg
         "qpop"
         "--config" "extensions.mq="
         (if patch (list patch) '())))

(defun monky-qpush (&optional patch)
  (interactive)
  (apply #'monky-run-hg
         "qpush"
         "--config" "extensions.mq="
         (if patch (list patch) '())))

(defun monky-qpush-all ()
  (interactive)
  (monky-run-hg "qpush" "--all"
                "--config" "extensions.mq="))

(defun monky-qpop-all ()
  (interactive)
  (monky-run-hg "qpop" "--all"
                "--config" "extensions.mq="))

(defvar monky-log-edit-buffer-name "*monky-edit-log*"
  "Buffer name for composing commit messages.")

(defun monky-qrefresh ()
  (interactive)
  (if (not current-prefix-arg)
      (apply #'monky-run-hg "qrefresh"
             "--config" "extensions.mq="
             (append monky-staged-files monky-queue-staged-files))
    ;; get last commit message
    (with-current-buffer (get-buffer-create monky-log-edit-buffer-name)
      (monky-hg-insert
       (list "log" "--config" "extensions.mq="
             "--template" "{desc}" "-r" "-1")))
    (monky-pop-to-log-edit 'qrefresh)))

(defun monky-qremove (patch)
  (monky-run-hg "qremove" patch
                "--config" "extensions.mq="))

(defun monky-qnew (patch)
  (interactive (list (read-string "Patch Name : ")))
  (if (not current-prefix-arg)
      (monky-run-hg "qnew" patch
                    "--config" "extensions.mq=")
    (monky-pop-to-log-edit 'qnew patch)))

(defun monky-qinit ()
  (interactive)
  (monky-run-hg "qinit"
                "--config" "extensions.mq="))

(defun monky-qimport (node-1 &optional node-2)
  (monky-run-hg "qimport" "--rev"
                (if node-2 (concat node-1 ":" node-2) node-1)
                "--config" "extensions.mq="))

(defun monky-qrename (old-patch &optional new-patch)
  (let ((new-patch (or new-patch
                       (read-string "New Patch Name : "))))
    (monky-run-hg "qrename" old-patch new-patch
                  "--config" "extensions.mq=")))

(defun monky-qfold (patch)
  (monky-run-hg "qfold" patch
                "--config" "extensions.mq="))

(defun monky-qguard (patch)
  (let ((guards (monky-parse-args (read-string "Guards : "))))
    (apply #'monky-run-hg "qguard" patch
           "--config" "extensions.mq="
           "--" guards)))

(defun monky-qselect ()
  (interactive)
  (let ((guards (monky-parse-args (read-string "Guards : "))))
    (apply #'monky-run-hg "qselect"
           "--config" "extensions.mq="
           guards)))

(defun monky-qfinish (patch)
  (monky-run-hg "qfinish" patch
                "--config" "extensions.mq="))

(defun monky-qfinish-applied ()
  (interactive)
  (monky-run-hg "qfinish" "--applied"
                "--config" "extensions.mq="))

(defun monky-qreorder ()
  "Pop all patches and edit .hg/patches/series file to reorder them"
  (interactive)
  (let ((series (monky-patch-series-file)))
   (monky-qpop-all)
   (with-current-buffer (get-buffer-create monky-log-edit-buffer-name)
     (erase-buffer)
     (insert-file-contents series))
   (monky-pop-to-log-edit 'qreorder)))

(defun monky-queue-stage-all ()
  "Add all items in Changes to the staging area."
  (interactive)
  (monky-with-refresh
    (setq monky-queue-staged-all-files t)
    (monky-refresh-buffer)))

(defun monky-queue-unstage-all ()
  "Remove all items from the staging area"
  (interactive)
  (monky-with-refresh
    (setq monky-queue-staged-files '())
    (monky-refresh-buffer)))

(defun monky-qimport-item ()
  (interactive)
  (monky-section-action "qimport"
    ((log commits commit)
     (if (region-active-p)
	 (monky-qimport
	  (monky-section-info (monky-section-at (monky-next-sha1 (region-beginning))))
	  (monky-section-info (monky-section-at
			       (monky-previous-sha1 (- (region-end) 1)))))
       (monky-qimport (monky-section-info (monky-current-section)))))))

(defun monky-qpop-item ()
  (interactive)
  (monky-section-action "qpop"
    ((applied patch)
     (monky-qpop (monky-section-info (monky-current-section)))
     (monky-qpop))
    ((applied)
     (monky-qpop-all))
    ((staged diff)
     (monky-unstage-file (monky-section-title (monky-current-section)))
     (monky-queue-unstage-file (monky-section-title (monky-current-section)))
     (monky-refresh-buffer))
    ((staged)
     (monky-unstage-all)
     (monky-queue-unstage-all))
    ((queue-staged diff)
     (monky-unstage-file (monky-section-title (monky-current-section)))
     (monky-queue-unstage-file (monky-section-title (monky-current-section)))
     (monky-refresh-buffer))
    ((queue-staged)
     (monky-unstage-all)
     (monky-queue-unstage-all))))

(defun monky-qpush-item ()
  (interactive)
  (monky-section-action "qpush"
    ((unapplied patch)
     (monky-qpush (monky-section-info (monky-current-section))))
    ((unapplied)
     (monky-qpush-all))
    ((untracked file)
     (monky-run-hg "add" (monky-section-info (monky-current-section))))
    ((untracked)
     (monky-run-hg "add"))
    ((missing file)
     (monky-run-hg "remove" "--after" (monky-section-info (monky-current-section))))
    ((changes diff)
     (monky-stage-file (monky-section-title (monky-current-section)))
     (monky-queue-stage-file (monky-section-title (monky-current-section)))
     (monky-refresh-buffer))
    ((changes)
     (monky-stage-all)
     (monky-queue-stage-all))
    ((discarding diff)
     (monky-stage-file (monky-section-title (monky-current-section)))
     (monky-queue-stage-file (monky-section-title (monky-current-section)))
     (monky-refresh-buffer))
    ((discarding)
     (monky-stage-all)
     (monky-queue-stage-all))))

(defun monky-qremove-item ()
  (interactive)
  (monky-section-action "qremove"
    ((unapplied patch)
     (monky-qremove (monky-section-info (monky-current-section))))))

(defun monky-qrename-item ()
  (interactive)
  (monky-section-action "qrename"
    ((patch)
     (monky-qrename (monky-section-info (monky-current-section))))))

(defun monky-qfold-item ()
  (interactive)
  (monky-section-action "qfold"
    ((unapplied patch)
     (monky-qfold (monky-section-info (monky-current-section))))))

(defun monky-qguard-item ()
  (interactive)
  (monky-section-action "qguard"
    ((patch)
     (monky-qguard (monky-section-info (monky-current-section))))))

(defun monky-qfinish-item ()
  (interactive)
  (monky-section-action "qfinish"
    ((applied patch)
     (monky-qfinish (monky-section-info (monky-current-section))))))

;;; Log edit mode

(define-derived-mode monky-log-edit-mode text-mode "Monky Log Edit")

(defun monky-restore-pre-log-edit-window-configuration ()
  (when monky-pre-log-edit-window-configuration
    (set-window-configuration monky-pre-log-edit-window-configuration)
    (setq monky-pre-log-edit-window-configuration nil)))

(defun monky-log-edit-commit ()
  "Finish edit and commit."
  (interactive)
  (when (= (buffer-size) 0)
    (user-error "No %s message" monky-log-edit-operation))
  (let ((commit-buf (current-buffer)))
    (case monky-log-edit-operation
      ('commit
       (with-current-buffer (monky-find-status-buffer default-directory)
         (apply #'monky-run-async-with-input commit-buf
                monky-hg-executable
                (append monky-hg-standard-options
                        (list "commit" "--logfile" "-")
                        monky-staged-files))))
      ('amend
       (with-current-buffer (monky-find-status-buffer default-directory)
         (apply #'monky-run-async-with-input commit-buf
                monky-hg-executable
                (append monky-hg-standard-options
                        (list "commit" "--amend" "--logfile" "-")
                        monky-staged-files))))
      ('backout
       (with-current-buffer monky-log-edit-client-buffer
         (monky-run-async-with-input commit-buf
                                   monky-hg-executable
                                   "backout"
                                   "--merge"
                                   "--logfile" "-"
                                   monky-log-edit-info)))
      ('qnew
       (with-current-buffer monky-log-edit-client-buffer
         (monky-run-async-with-input commit-buf
                                     monky-hg-executable
                                     "qnew" monky-log-edit-info
                                     "--config" "extensions.mq="
                                     "--logfile" "-")))
      ('qrefresh
       (with-current-buffer monky-log-edit-client-buffer
         (apply #'monky-run-async-with-input commit-buf
                monky-hg-executable "qrefresh"
                "--config" "extensions.mq="
                "--logfile" "-"
                (append monky-staged-files monky-queue-staged-files))))
      ('qreorder
       (let* ((queue-buffer (monky-find-buffer 'queue))
	      (series (with-current-buffer queue-buffer
			(monky-patch-series-file))))
	(with-current-buffer monky-log-edit-buffer-name
	  (write-region (point-min) (point-max) series))
	(with-current-buffer queue-buffer
	  (monky-refresh))))))
  (erase-buffer)
  (bury-buffer)
  (monky-restore-pre-log-edit-window-configuration))

(defun monky-log-edit-cancel-log-message ()
  "Abort edits and erase commit message being composed."
  (interactive)
  (when (or (not monky-log-edit-confirm-cancellation)
            (yes-or-no-p
             "Really cancel editing the log (any changes will be lost)?"))
    (erase-buffer)
    (bury-buffer)
    (monky-restore-pre-log-edit-window-configuration)))

(defun monky-pop-to-log-edit (operation &optional info)
  (let ((dir default-directory)
        (buf (get-buffer-create monky-log-edit-buffer-name)))
    (setq monky-pre-log-edit-window-configuration
          (current-window-configuration)
          monky-log-edit-operation operation
          monky-log-edit-client-buffer (current-buffer)
          monky-log-edit-info info)
    (pop-to-buffer buf)
    (setq default-directory dir)
    (monky-log-edit-mode)
    (message "Type C-c C-c to %s (C-c C-k to cancel)." monky-log-edit-operation)))

(defun monky-log-edit ()
  "Bring up a buffer to allow editing of commit messages."
  (interactive)
  (when (not (or monky-staged-files (monky-merge-p)))
    (if (y-or-n-p "Nothing staged. Stage and commit all changes? ")
        (monky-stage-all)
      (user-error "Nothing staged")))
  (monky-pop-to-log-edit 'commit))

(defun monky-commit-amend ()
  "Amends previous commit.
Brings up a buffer to allow editing of commit message."
  (interactive)
  ;; get last commit message
  (with-current-buffer (get-buffer-create monky-log-edit-buffer-name)
    (monky-hg-insert
     (list "log"
           "--template" "{desc}" "-r" ".")))
  (monky-pop-to-log-edit 'amend))

(defun monky-bookmark-create (bookmark-name)
  "Create a bookmark at the current location"
  (interactive "sBookmark name: ")
  (monky-run-hg-async "bookmark" bookmark-name))

(defun monky-killall-monky-buffers ()
  (interactive)
  (cl-flet ((monky-buffer-p (b) (string-match "\*monky\\(:\\|-\\).*" (buffer-name b))))
    (let ((monky-buffers (cl-remove-if-not #'monky-buffer-p (buffer-list))))
      (cl-loop for mb in monky-buffers
               do
               (kill-buffer mb)))))

(provide 'monky)

;; Local Variables:
;; byte-compile-warnings: (not cl-functions)
;; End:

;;; monky.el ends here
