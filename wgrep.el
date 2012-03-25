;;; wgrep.el --- Writable grep buffer and apply the changes to files

;; Author: Masahiro Hayashi <mhayashi1120@gmail.com>
;; Keywords: grep edit extensions
;; URL: http://github.com/mhayashi1120/Emacs-wgrep/raw/master/wgrep.el
;; Emacs: GNU Emacs 22 or later
;; Version: 2.0.0

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; wgrep allows you to edit a grep buffer and apply those changes to
;; the file buffer.

;;; Install:

;; Put this file into load-path'ed directory, and byte compile it if
;; desired. And put the following expression into your ~/.emacs.
;;
;;     (require 'wgrep)

;;; Usage:

;; You can edit the text in the *grep* buffer after typing C-c C-p.
;; After that the changed text is highlighted.
;; The following keybindings are defined:

;; C-c C-e : Apply the changes to file buffers.
;; C-c C-u : All changes are unmarked and ignored.
;; C-c C-d : Delete current line (including newline).
;;           This is immediately reflected in the file's buffer.
;; C-c C-r : Remove the changes in the region (these changes are not
;;           applied to the files. Of course, the remaining
;;           changes can still be applied to the files.)
;; C-c C-p : Toggle read-only area.
;; C-c C-k : Discard all changes and exit.
;; C-x C-q : Exit wgrep mode.

;; * To save all buffers that wgrep has changed, run
;;
;;   M-x wgrep-save-all-buffers

;; * You can change the default key binding to switch to wgrep.
;;
;; (setq wgrep-enable-key "r")

;; * To apply all changes wheather or not buffer is read-only.
;;
;; (setq wgrep-change-readonly-file t)

;;; History:

;; This program is a forked version. the original version can be downloaded from
;; http://www.bookshelf.jp/elc/grep-edit.el

;; Following added implementations and differences.
;; * Support GNU grep context option -A -B and -C
;; * Some bugfix. (wrong coloring text etc..)
;; * wdired.el like interface.
;; * Remove all advice.
;; * Bind to local variables. (grep-a-lot.el works well)
;; * After save buffer, colored face will be removed.
;; * Change face easy to see.
;; * Reinforce checking error.
;; * Support removing whole line include new-line.

;;; Code:

(require 'grep)

(declare-function image-get-display-property "image-mode.el" ())
(declare-function image-mode-as-text "image-mode.el" ())

(defgroup wgrep nil
  "Customize wgrep"
  :group 'grep)

(defcustom wgrep-change-readonly-file nil
  "*Non-nil means to enable change read-only files."
  :group 'wgrep
  :type 'boolean)

(defcustom wgrep-enable-key "\C-c\C-p"
  "*Key to enable `wgrep-mode'."
  :type 'string
  :group 'wgrep)

(defvar wgrep-setup-hook nil
  "Hooks to run when setting up wgrep.")

(defface wgrep-face
  '((((class color)
      (background dark))
     (:background "SlateGray1" :weight bold :foreground "Black"))
    (((class color)
      (background light))
     (:background "ForestGreen" :weight bold :foreground "white"))
    (t
     ()))
  "*Face used for the changed text in the grep buffer."
  :group 'wgrep)

(defface wgrep-file-face
  '((((class color)
      (background dark))
     (:background "gray30" :weight bold :foreground "white"))
    (((class color)
      (background light))
     (:background "ForestGreen" :weight bold :foreground "white"))
    (t
     ()))
  "*Face used for the changed text in the file buffer."
  :group 'wgrep)

(defface wgrep-reject-face
  '((((class color)
      (background dark))
     (:foreground "hot pink" :weight bold))
    (((class color)
      (background light))
     (:foreground "red" :weight bold))
    (t
     ()))
  "*Face used for the line in the grep buffer that can not be applied to
a file."
  :group 'wgrep)

(defface wgrep-done-face
  '((((class color)
      (background dark))
     (:foreground "LightSkyBlue" :weight bold))
    (((class color)
      (background light))
     (:foreground "blue" :weight bold))
    (t
     ()))
  "*Face used for the line in the grep buffer that can be applied to a file."
  :group 'wgrep)

(defvar wgrep-overlays nil)
(make-variable-buffer-local 'wgrep-overlays)

(defvar wgrep-file-overlays nil)
(make-variable-buffer-local 'wgrep-file-overlays)

(defvar wgrep-readonly-state nil)
(make-variable-buffer-local 'wgrep-readonly-state)

(defvar wgrep-each-other-buffer nil)
(make-variable-buffer-local 'wgrep-each-other-buffer)

;; Suppress elint warning
;; GNU Emacs have this variable at least version 21 or later
(defvar auto-coding-regexp-alist)

(defconst wgrep-line-file-regexp (caar grep-regexp-alist))
(defvar wgrep-inhibit-modification-hook nil)

(defvar wgrep-mode-map nil)
(unless wgrep-mode-map
  (setq wgrep-mode-map
        (let ((map (make-sparse-keymap)))

          (define-key map "\C-c\C-c" 'wgrep-finish-edit)
          (define-key map "\C-c\C-d" 'wgrep-flush-current-line)
          (define-key map "\C-c\C-e" 'wgrep-finish-edit)
          (define-key map "\C-c\C-p" 'wgrep-toggle-readonly-area)
          (define-key map "\C-c\C-r" 'wgrep-remove-change)
          (define-key map "\C-x\C-s" 'wgrep-finish-edit)
          (define-key map "\C-c\C-u" 'wgrep-remove-all-change)
          (define-key map "\C-c\C-[" 'wgrep-remove-all-change)
          (define-key map "\C-c\C-k" 'wgrep-abort-changes)
          (define-key map "\C-x\C-q" 'wgrep-exit)
          (define-key map "\C-m"     'ignore)
          (define-key map "\C-j"     'ignore)
          (define-key map "\C-o"     'ignore)

          map)))

;;;###autoload
(defun wgrep-setup ()
  "Setup wgrep preparation."
  (define-key grep-mode-map wgrep-enable-key 'wgrep-change-to-wgrep-mode)
  ;; delete previous wgrep overlays
  (wgrep-cleanup-overlays (point-min) (point-max))
  (remove-hook 'post-command-hook 'wgrep-maybe-echo-error-at-point t)
  (run-hooks 'wgrep-setup-hook))

(defun wgrep-maybe-echo-error-at-point ()
  (when (null (current-message))
    (let ((ov (catch 'found
               (dolist (o (overlays-in
                           (line-beginning-position) (line-end-position)))
                 (when (overlay-get o 'wgrep-reject-message)
                   (throw 'found o))))))
      (when ov
        (let (message-log-max)
          (message "%s" (overlay-get ov 'wgrep-reject-message)))))))

(defun wgrep-set-readonly-area (state)
  (let ((inhibit-read-only t)
        (wgrep-inhibit-modification-hook t)
        (regexp (format "\\(?:%s\\|\n\\)" wgrep-line-file-regexp)))
    (save-excursion
      (wgrep-goto-first-found)
      (while (re-search-forward regexp nil t)
        (wgrep-set-readonly-property
         (match-beginning 0) (match-end 0) state)))
    (setq wgrep-readonly-state state)))

(defun wgrep-after-change-function (beg end leng-before)
  (cond
   (wgrep-inhibit-modification-hook nil)
   ((= (point-min) (point-max))
    ;; cleanup when first executing
    (wgrep-cleanup-overlays (point-min) (point-max)))
   (t
    (wgrep-put-change-face beg end))))

(defun wgrep-get-edit-info (ov)
  (goto-char (overlay-start ov))
  (forward-line 0)
  (when (looking-at wgrep-line-file-regexp)
    (let* ((name (match-string-no-properties 1))
           (line (match-string-no-properties 3))
           (start (match-end 0))
           (file (expand-file-name name default-directory))
           result)
      ;; get a result overlay. (that is not a changed overlay)
      (catch 'done
        (dolist (o (overlays-in (overlay-start ov) (overlay-end ov)))
          (when (overlay-get o 'wgrep-result)
            (setq result o)))
        (setq result (wgrep-make-overlay start (overlay-end ov)))
        (overlay-put result 'wgrep-result t))
      (list (wgrep-get-file-buffer file)
            (string-to-number line)
            result))))

(defun wgrep-get-flush-overlay ()
  (catch 'done
    ;; get existing overlay
    (dolist (o (overlays-in (line-beginning-position) (line-end-position)))
      (when (overlay-get o 'wgrep)
        (throw 'done o)))
    (wgrep-make-overlay (line-beginning-position) (line-end-position))))

(put 'wgrep-error 'error-conditions '(wgrep-error error))
(put 'wgrep-error 'error-message "Error while applying changes.")

(defun wgrep-get-file-buffer (file)
  (unless (file-exists-p file)
    (signal 'wgrep-error "File does not exist."))
  (unless (file-writable-p file)
    (signal 'wgrep-error "File is not writable."))
  (or (get-file-buffer file)
      (find-file-noselect file)))

(defun wgrep-check-buffer ()
  "Check the file's status. If it is possible to change the file, return t"
  (when (and (not wgrep-change-readonly-file)
             buffer-read-only)
    (signal 'wgrep-error (format "Buffer \"%s\" is read-only." (buffer-name)))))

(defun wgrep-display-physical-data ()
  (cond
   ;; `funcall' is a trick to suppress the elint warnings.
   ((derived-mode-p 'image-mode)
    ;; toggle to raw data if buffer has image.
    (when (image-get-display-property)
      (image-mode-as-text)))
   (t nil)))

;; not consider other edit. (ex: Undo or self-insert-command)
(defun wgrep-after-save-hook ()
  (remove-hook 'after-save-hook 'wgrep-after-save-hook t)
  (dolist (ov wgrep-file-overlays)
    (delete-overlay ov))
  (kill-local-variable 'wgrep-file-overlays))

(defun wgrep-apply-to-buffer (buffer old line &optional new)
  "*The changes in the grep buffer are applied to the file"
  (with-current-buffer buffer
    (let ((inhibit-read-only wgrep-change-readonly-file)
          (coding buffer-file-coding-system))
      (wgrep-check-buffer)
      (wgrep-display-physical-data)
      (save-restriction
        (widen)
        (wgrep-goto-line line)
        ;;FIXME simply do this?
        (when (and (= line 1)
                   coding
                   (coding-system-get coding :bom))
          (setq old (wgrep-string-replace-bom old coding))
          (when new
            (setq new (wgrep-string-replace-bom new coding))))
        (unless (string= old
                         (buffer-substring
                          (line-beginning-position) (line-end-position)))
          (signal 'wgrep-error "Buffer was changed after grep."))
        (cond
         (new
          (wgrep-replace-to-new-line new))
         (t
          ;; new nil means flush whole line.
          (wgrep-flush-pop-deleting-line)))))))

(defun wgrep-replace-to-new-line (new-text)
  ;; delete grep extracted region (restricted to a line)
  (delete-region (line-beginning-position) (line-end-position))
  (let ((beg (point))
        end)
    (insert new-text)
    (setq end (point))
    ;; hilight the changed line
    (wgrep-put-color-file beg end)))

;;Hack function
(defun wgrep-string-replace-bom (string cs)
  (let ((regexp (car (rassq (coding-system-base cs) auto-coding-regexp-alist)))
        ;; FIXME: `find-operation-coding-system' is not exactly correct.
        ;;        However almost case is ok like this bom function.
        ;;        ex: (let ((default-process-coding-system 'some-coding))
        ;;               (call-interactively 'grep))
        (grep-cs (or (find-operation-coding-system 'call-process grep-program)
                     (terminal-coding-system)))
        str)
    (if (and regexp
             (setq str (encode-coding-string string grep-cs))
             (string-match regexp str))
        (decode-coding-string (substring str (match-end 0)) cs)
      string)))

(defun wgrep-put-color-file (beg end)
  "*Highlight the changes in the file"
  (let ((ov (wgrep-make-overlay beg end)))
    (overlay-put ov 'face 'wgrep-file-face)
    (overlay-put ov 'priority 0)
    (add-hook 'after-save-hook 'wgrep-after-save-hook nil t)
    (setq wgrep-file-overlays (cons ov wgrep-file-overlays))))

(defun wgrep-put-done-face (ov)
  (wgrep-set-face ov 'wgrep-done-face))

(defun wgrep-put-reject-face (ov message)
  (wgrep-set-face ov 'wgrep-reject-face message))

(defun wgrep-set-face (ov face &optional message)
  (overlay-put ov 'face face)
  (overlay-put ov 'priority 1)
  (overlay-put ov 'wgrep-reject-message message))

(defun wgrep-put-change-face (beg end)
  (save-excursion
    ;; looking-at destroy replace regexp..
    (save-match-data
      (let ((ov (wgrep-get-editing-overlay beg end)))
        ;; delete overlay if text is same as old value.
        (cond
         ((null ov))                    ; not a valid point
         ((string= (overlay-get ov 'wgrep-old-text)
                   (overlay-get ov 'wgrep-edit-text))
          ;; back to unchanged
          (setq wgrep-overlays (remq ov wgrep-overlays))
          (delete-overlay ov))
         ((not (memq ov wgrep-overlays))
          ;; register overlay
          (setq wgrep-overlays (cons ov wgrep-overlays))))))))

(defun wgrep-get-editing-overlay (beg end)
  (goto-char beg)
  (let ((bol (line-beginning-position))
        ov eol)
    (goto-char end)
    (setq eol (line-end-position))
    (catch 'done
      (dolist (o (overlays-in bol eol))
        ;; find overlay that have changed by user.
        (when (overlay-get o 'wgrep-changed)
          (setq ov o)
          (throw 'done o))))
    (when ov
      (setq bol (min beg (overlay-start ov))
            eol (max (overlay-end ov) end)))
    (goto-char bol)
    (when (looking-at wgrep-line-file-regexp)
      (let* ((header (match-string-no-properties 0))
             (value (buffer-substring-no-properties (match-end 0) eol)))
        (unless ov
          (let ((old (wgrep-get-old-text header)))
            (setq ov (wgrep-make-overlay bol eol))
            (overlay-put ov 'wgrep-changed t)
            (overlay-put ov 'face 'wgrep-face)
            (overlay-put ov 'priority 0)
            (overlay-put ov 'wgrep-old-text old)))
        (move-overlay ov bol eol)
        (overlay-put ov 'wgrep-edit-text value)))
    ov))

(defun wgrep-to-grep-mode ()
  (kill-local-variable 'query-replace-skip-read-only)
  (remove-hook 'after-change-functions 'wgrep-after-change-function t)
  ;; do not remove `wgrep-maybe-echo-error-at-point' that display
  ;; errors at point
  (use-local-map grep-mode-map)
  (set-buffer-modified-p nil)
  (setq buffer-undo-list nil)
  (setq buffer-read-only t))

(defun wgrep-changed-overlay-action (ov)
  (let (info)
    (cond
     ((eq (overlay-start ov) (overlay-end ov))
      ;; ignore removed line or removed overlay
      t)
     ((null (setq info (wgrep-get-edit-info ov)))
      ;; ignore non grep result line.
      t)
     (t
      (let* ((buffer (nth 0 info))
             (line (nth 1 info))
             (result (nth 2 info))
             (old (overlay-get ov 'wgrep-old-text))
             (new (overlay-get ov 'wgrep-edit-text)))
        (condition-case err
            (progn
              (wgrep-apply-to-buffer buffer old line new)
              (wgrep-put-done-face result)
              t)
          (wgrep-error
           (wgrep-put-reject-face result (cdr err))
           nil)
          (error
           (wgrep-put-reject-face result (prin1-to-string err))
           nil)))))))

(defun wgrep-finish-edit ()
  "Apply changes to file buffers."
  (interactive)
  (let ((count 0))
    (save-excursion
      (let ((not-yet (copy-sequence wgrep-overlays)))
        (dolist (ov wgrep-overlays)
          (when (wgrep-changed-overlay-action ov)
            (delete-overlay ov)
            (setq not-yet (delq ov not-yet))
            (setq count (1+ count))))
        ;; restore overlays
        (setq wgrep-overlays not-yet)))
    (wgrep-cleanup-temp-buffer)
    (wgrep-to-grep-mode)
    (let ((msg (format "(%d changed)" count)))
      (cond
       ((null wgrep-overlays)
        (if (= count 0)
            (message "(No changes to be performed)")
          (message "Successfully finished. %s" msg)))
       ((= (length wgrep-overlays) 1)
        (message "There is an unapplied change. %s" msg))
       (t
        (message "There are %d unapplied changes. %s"
                 (length wgrep-overlays) msg))))))

(defun wgrep-exit ()
  "Return to `grep-mode'"
  (interactive)
  (if (and (buffer-modified-p)
           (y-or-n-p (format "Buffer %s modified; save changes? "
                             (current-buffer))))
      (wgrep-finish-edit)
    (wgrep-abort-changes)))

(defun wgrep-abort-changes ()
  "Discard all changes and return to `grep-mode'"
  (interactive)
  (wgrep-cleanup-overlays (point-min) (point-max))
  (wgrep-restore-from-temp-buffer)
  (wgrep-to-grep-mode)
  (message "Changes discarded"))

(defun wgrep-remove-change (beg end)
  "Remove changes in the region between BEG and END."
  (interactive "r")
  (wgrep-cleanup-overlays beg end)
  (setq mark-active nil))

(defun wgrep-remove-all-change ()
  "Remove changes in the whole buffer."
  (interactive)
  (wgrep-cleanup-overlays (point-min) (point-max)))

(defun wgrep-toggle-readonly-area ()
  "Toggle read-only area to remove a whole line.

See the following example: you obviously don't want to edit the first line.
If grep matches a lot of lines, it's hard to edit the grep buffer.
After toggling to editable, you can call
`delete-matching-lines', `delete-non-matching-lines'.

Example:
----------------------------------------------
./.svn/text-base/some.el.svn-base:87:(hoge)
./some.el:87:(hoge)
----------------------------------------------
"
  (interactive)
  (let ((modified (buffer-modified-p))
        (read-only (not wgrep-readonly-state)))
    (wgrep-set-readonly-area read-only)
    (wgrep-set-header/footer-read-only read-only)
    (set-buffer-modified-p modified)
    (if wgrep-readonly-state
        (message "Removing the whole line is now disabled.")
      (message "Removing the whole line is now enabled."))))

(defun wgrep-change-to-wgrep-mode ()
  "Change to wgrep mode.

When the *grep* buffer is huge, this might freeze your Emacs
for several minutes.
"
  (interactive)
  (unless (eq major-mode 'grep-mode)
    (error "Not a grep buffer"))
  (unless (wgrep-process-exited-p)
    (error "Active process working"))
  (wgrep-prepare-to-edit)
  (wgrep-set-readonly-area t)
  (set (make-local-variable 'query-replace-skip-read-only) t)
  (add-hook 'after-change-functions 'wgrep-after-change-function nil t)
  (add-hook 'post-command-hook 'wgrep-maybe-echo-error-at-point nil t)
  (use-local-map wgrep-mode-map)
  (buffer-disable-undo)
  (wgrep-clone-to-temp-buffer)
  (setq buffer-read-only nil)
  (buffer-enable-undo)
  (set-buffer-modified-p wgrep-overlays) ;; restore modified status
  (setq buffer-undo-list nil)
  (message "%s" (substitute-command-keys
                 "Press \\[wgrep-finish-edit] when finished \
or \\[wgrep-abort-changes] to abort changes.")))

(defun wgrep-save-all-buffers ()
  "Save the buffers that wgrep changed."
  (interactive)
  (let ((count 0))
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (and (local-variable-p 'wgrep-file-overlays)
                   wgrep-file-overlays
                   (buffer-modified-p))
          (basic-save-buffer)
          (setq count (1+ count)))))
    (cond
     ((= count 0)
      (message "No buffer has been saved."))
     ((= count 1)
      (message "Buffer has been saved."))
     (t
      (message "%d buffers have been saved." count)))))

(defun wgrep-flush-current-line ()
  "Flush current line and file buffer. Undo is disabled for this command.
This command immediately changes the file buffer, although the buffer
is not saved.
"
  (interactive)
  (save-excursion
    (let ((inhibit-read-only t))
      (forward-line 0)
      (unless (looking-at wgrep-line-file-regexp)
        (error "Not a grep result"))
      (let* ((header (match-string-no-properties 0))
             (filename (match-string-no-properties 1))
             (line (string-to-number (match-string 3)))
             (ov (wgrep-get-flush-overlay))
             (old (wgrep-get-old-text header)))
        (let ((inhibit-quit t)
              (wgrep-inhibit-modification-hook t))
          (when (wgrep-flush-apply-to-buffer filename ov line old)
            (delete-overlay ov)
            ;; disable undo temporarily and change *grep* buffer.
            (let ((buffer-undo-list t))
              (wgrep-delete-whole-line)
              (wgrep-after-delete-line filename line))
            ;; correct evacuated buffer
            (with-current-buffer wgrep-each-other-buffer
              (let ((inhibit-read-only t))
                (wgrep-after-delete-line filename line)))))))))

(defun wgrep-after-delete-line (filename delete-line)
  (save-excursion
    (wgrep-goto-first-found)
    (let ((regexp (format "^%s\\(?::\\)\\([0-9]+\\)\\(?::\\)"
                          (regexp-quote filename))))
      (while (not (eobp))
        (when (looking-at regexp)
          (let ((line (string-to-number (match-string 1)))
                (read-only (get-text-property (point) 'read-only)))
            (cond
             ((= line delete-line)
              ;; for cloned buffer (flush same line number)
              (wgrep-delete-whole-line)
              (forward-line -1))
             ((> line delete-line)
              ;; down line number
              (let ((line-head (format "%s:%d:" filename (1- line))))
                (wgrep-set-readonly-property
                 0 (length line-head) read-only line-head)
                (replace-match line-head nil nil nil 0))))))
        (forward-line 1)))))

(defun wgrep-prepare-context ()
  (wgrep-goto-first-found)
  (while (not (eobp))
    (cond
     ((looking-at wgrep-line-file-regexp)
      (let ((filename (match-string 1))
            (line (string-to-number (match-string 3))))
        ;; delete backward and forward following options.
        ;; -A (--after-context) -B  (--before-context) -C (--context)
        (save-excursion
          (wgrep-prepare-context-while filename line nil))
        (wgrep-prepare-context-while filename line t)
        (forward-line -1)))
     ((looking-at "^--$")
      (wgrep-delete-whole-line)
      (forward-line -1)))
    (forward-line 1)))

(defun wgrep-delete-whole-line ()
  (wgrep-delete-region
   (line-beginning-position) (line-beginning-position 2)))

(defun wgrep-goto-first-found ()
  (goto-char (point-min))
  (when (re-search-forward "^Grep " nil t)
    ;; See `compilation-start'
    (forward-line 3)))

(defun wgrep-goto-end-of-found ()
  (goto-char (point-max))
  (re-search-backward "^Grep " nil t))

(defun wgrep-goto-line (line)
  (goto-char (point-min))
  (forward-line (1- line)))

;; -A -B -C output may be misunderstood and set read-only.
;; (ex: filename-20-2010/01/01 23:59:99)
(defun wgrep-prepare-context-while (filename line forward)
  (let* ((diff (if forward 1 -1))
         (next (+ diff line)))
    (forward-line diff)
    (while (looking-at (format "^%s\\(-\\)%d\\(-\\)" filename next))
      (let ((line-head (format "%s:%d:" filename next)))
        (replace-match line-head nil nil nil 0)
        (forward-line diff)
        (setq next (+ diff next))))))

(defun wgrep-delete-region (min max)
  (remove-text-properties min max '(read-only) (current-buffer))
  (delete-region min max))

(defun wgrep-process-exited-p ()
  (let ((proc (get-buffer-process (current-buffer))))
    (or (null proc)
        (eq (process-status proc) 'exit))))

(defun wgrep-set-readonly-property (start end value &optional object)
  (put-text-property start end 'read-only value object)
  ;; This means grep header (filename and line num) that rear is editable text.
  ;; Header text length will always be greater than 2.
  (when (> end (1+ start))
    (add-text-properties (1- end) end '(rear-nonsticky t) object)))

(defun wgrep-prepare-to-edit ()
  (save-excursion
    (let ((inhibit-read-only t)
          (wgrep-inhibit-modification-hook t)
          buffer-read-only beg end)
      ;; Set read-only grep result header
      (setq beg (point-min))
      (wgrep-goto-first-found)
      (setq end (point))
      (put-text-property beg end 'read-only t)
      (put-text-property beg end 'wgrep-header t)
      ;; Set read-only grep result footer
      (wgrep-goto-end-of-found)
      (setq beg (point))
      (setq end (point-max))
      (when beg
        (put-text-property beg end 'read-only t)
        (put-text-property beg end 'wgrep-footer t))
      (wgrep-prepare-context))))

(defun wgrep-set-header/footer-read-only (state)
  (let ((inhibit-read-only t)
        (wgrep-inhibit-modification-hook t))
    ;; header
    (let ((header-end (next-single-property-change (point-min) 'wgrep-header)))
      (when header-end
        (put-text-property (point-min) header-end 'read-only state)))
    ;; footer
    (let ((footer-beg (next-single-property-change (point-min) 'wgrep-footer)))
      (when footer-beg
        (put-text-property footer-beg (point-max) 'read-only state)))))

(defun wgrep-cleanup-overlays (beg end)
  (dolist (ov (overlays-in beg end))
    (when (overlay-get ov 'wgrep)
      (delete-overlay ov))))

(defun wgrep-make-overlay (beg end)
  (let ((o (make-overlay beg end nil nil t)))
    (overlay-put o 'wgrep t)
    o))

(defun wgrep-clone-to-temp-buffer ()
  (wgrep-cleanup-temp-buffer)
  (let ((grepbuf (current-buffer))
        (tmpbuf (generate-new-buffer " *wgrep temp* ")))
    (setq wgrep-each-other-buffer tmpbuf)
    (add-hook 'kill-buffer-hook 'wgrep-cleanup-temp-buffer nil t)
    (append-to-buffer tmpbuf (point-min) (point-max))
    (with-current-buffer tmpbuf
      (setq wgrep-each-other-buffer grepbuf))
    tmpbuf))

(defun wgrep-restore-from-temp-buffer ()
  (cond
   ((and wgrep-each-other-buffer
         (buffer-live-p wgrep-each-other-buffer))
    (let ((grepbuf (current-buffer))
          (tmpbuf wgrep-each-other-buffer)
          (savedh (wgrep-current-header))
          (savedc (current-column))
          (savedp (point))
          (inhibit-read-only t)
          (wgrep-inhibit-modification-hook t)
          buffer-read-only)
      (erase-buffer)
      (with-current-buffer tmpbuf
        (append-to-buffer grepbuf (point-min) (point-max)))
      (goto-char (point-min))
      (or (and savedh
               (re-search-forward (concat "^" (regexp-quote savedh)) nil t)
               (move-to-column savedc))
          (goto-char (min (point-max) savedp)))
      (wgrep-cleanup-temp-buffer)
      (setq wgrep-overlays nil)))
   (t
    ;; non fatal error
    (message "Error! Saved buffer is unavailable."))))

(defun wgrep-cleanup-temp-buffer ()
  "Cleanup temp buffer in *grep* buffer."
  (when (memq major-mode '(grep-mode))
    (let ((grep-buffer (current-buffer)))
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (when (eq grep-buffer wgrep-each-other-buffer)
            (kill-buffer buf)))))
    (setq wgrep-each-other-buffer nil)))

(defun wgrep-current-header ()
  (save-excursion
    (forward-line 0)
    (when (looking-at wgrep-line-file-regexp)
      (match-string-no-properties 0))))

(defun wgrep-get-old-text (header)
  (when (and wgrep-each-other-buffer
             (buffer-live-p wgrep-each-other-buffer))
    (with-current-buffer wgrep-each-other-buffer
      (goto-char (point-min))
      (when (re-search-forward (concat "^" (regexp-quote header)) nil t)
        (buffer-substring-no-properties (point) (line-end-position))))))

(defun wgrep-flush-pop-deleting-line ()
  (save-window-excursion
    (set-window-buffer (selected-window) (current-buffer))
    (wgrep-put-color-file
     (line-beginning-position) (line-end-position))
    (sit-for 0.3)
    (wgrep-delete-whole-line)
    (sit-for 0.3)))

(defun wgrep-flush-apply-to-buffer (filename ov line old)
  (let* ((file (expand-file-name filename default-directory))
         (buffer (wgrep-get-file-buffer file)))
    (condition-case err
        (progn
          (wgrep-apply-to-buffer buffer old line)
          t)
      (wgrep-error
       (wgrep-put-reject-face ov (cdr err))
       nil)
      (error
       (wgrep-put-reject-face ov (prin1-to-string err))
       nil))))

;;;
;;; TODO testing
;;;

(defun wgrep-undo-all-buffers ()
  "Undo buffers wgrep has changed."
  (interactive)
  (let ((count 0))
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (and (local-variable-p 'wgrep-file-overlays)
                   wgrep-file-overlays
                   (buffer-modified-p))
          ;;TODO undo only wgrep modification..
          (undo)
          (setq count (1+ count)))))
    (cond
     ((= count 0)
      (message "Undo no buffer."))
     ((= count 1)
      (message "Undo a buffer."))
     (t
      (message "Undo %d buffers." count)))))

(defun wgrep-map (function)
  (save-excursion
    (let (start end)
      (wgrep-goto-first-found)
      (setq start (point))
      (wgrep-goto-end-of-found)
      (setq end (point))
      (save-restriction
        (narrow-to-region start end)
        (goto-char (point-min))
        (while (not (eobp))
          (when (looking-at wgrep-line-file-regexp)
            (let* ((file (match-string-no-properties 1))
                   (buffer (wgrep-get-file-buffer file))
                   markers diff)
              (with-current-buffer buffer
                (setq markers (wgrep-map-line-markers))
                (save-excursion
                  (save-match-data
                    (funcall function)))
                (setq diff (wgrep-map-line-diff markers)))
              (wgrep-map-after-call file diff)
              (with-current-buffer wgrep-each-other-buffer
                (wgrep-map-after-call file diff))))
          (forward-line 1))))))

;;TODO not tested yet.
(defun wgrep-map-after-call (file diff)
  (let ((inhibit-read-only t)
        (file-regexp (regexp-quote file))
        after-change-functions)
    (save-excursion
      (dolist (pair diff)
        (let ((old (car pair))
              (new (cdr pair)))
          (goto-char (point-min))
          (when (re-search-forward (format "^%s:\\(%d\\):" file-regexp old) nil t)
            (replace-match (number-to-string new) nil nil nil 1)))))))

(defun wgrep-map-line-markers ()
  (let (markers)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (setq markers (cons (point-marker) markers))
        (forward-line 1)))
    (nreverse markers)))

;;TODO deleted line.
(defun wgrep-map-line-diff (markers)
  (let ((num 1)
        (ret '()))
    (dolist (marker markers)
      (let ((new (line-number-at-pos (marker-position marker))))
        (when (/= new num)
          (setq ret (cons (cons num new) ret))))
      (setq num (1+ num)))
    (nreverse ret)))

(defun wgrep-editing-list ()
  (let (info res)
    (dolist (ov wgrep-overlays res)
      (cond
        ;; ignore removed line or removed overlay
       ((eq (overlay-start ov) (overlay-end ov)))
       ;; ignore non grep result line.
       ((null (setq info (wgrep-get-edit-info ov))))
       (t
        (let* ((buffer (nth 0 info))
               (line (nth 1 info))
               (result (nth 2 info))
               (old (overlay-get ov 'wgrep-old-text))
               (new (overlay-get ov 'wgrep-edit-text)))
          (setq res
                (cons
                 (list buffer line old new result ov)
                 res))))))))

(defun wgrep-calculate-transaction ()
  (let ((edit-list (wgrep-editing-list))
        ;; key ::= buffer
        ;; value ::= edit ...
        ;; edit ::= line old-text new-text result-overlay edit-overlay
        buffer-alist)
    (dolist (x edit-list)
      (let ((pair (assq (car x) buffer-alist)))
        (unless pair
          (setq pair (cons (car x) nil))
          (setq buffer-alist (cons pair buffer-alist)))
        (setcdr pair (cons (cdr x) (cdr pair)))))
    (dolist (y buffer-alist)
      (with-current-buffer (car y)
        (save-restriction
          (widen)
          (dolist (z (cdr y))
            (wgrep-goto-line (car z))
            (setcar z (point-marker))))))
    buffer-alist))

(defun wgrep-commit-buffer (buffer tran)
  (with-current-buffer buffer
    (let ((inhibit-read-only wgrep-change-readonly-file)
          done)
      (wgrep-check-buffer)
      (wgrep-display-physical-data)
      (save-restriction
        (widen)
        (dolist (info tran)
          (let ((marker (nth 0 info))
                (old (nth 1 info))
                (new (nth 2 info))
                (result (nth 3 info))
                (ov (nth 4 info)))
            (condition-case err
                (progn
                  (wgrep-apply-change marker old new)
                  (wgrep-put-done-face result)
                  (delete-overlay ov)
                  (setq done (cons ov done)))
              (wgrep-error
               (wgrep-put-reject-face result (cdr err)))
              (error
               (wgrep-put-reject-face result (prin1-to-string err)))))))
      (nreverse done))))

(defun wgrep-finish-edit2 ()
  "Apply changes to file buffers."
  (interactive)
  (let ((all-tran (wgrep-calculate-transaction))
        done)
    (dolist (buf-tran all-tran)
      (let ((commited (wgrep-commit-buffer (car buf-tran) (cdr buf-tran))))
        (setq done (append done commited))))
    ;; restore overlays
    (dolist (ov done)
      (setq wgrep-overlays (delq ov wgrep-overlays)))
    (wgrep-cleanup-temp-buffer)
    (wgrep-to-grep-mode)
    (let ((msg (format "(%d changed)" (length done))))
      (cond
       ((null wgrep-overlays)
        (if (= (length done) 0)
            (message "(No changes to be performed)")
          (message "Successfully finished. %s" msg)))
       ((= (length wgrep-overlays) 1)
        (message "There is an unapplied change. %s" msg))
       (t
        (message "There are %d unapplied changes. %s"
                 (length wgrep-overlays) msg))))))

(defun wgrep-apply-change (marker old &optional new)
  "*The changes in the grep buffer are applied to the file"
  (let ((coding buffer-file-coding-system))
    (goto-char marker)
    (when (and (= (point-min-marker) marker)
               coding
               (coding-system-get coding :bom))
      (setq old (wgrep-string-replace-bom old coding))
      (when new
        (setq new (wgrep-string-replace-bom new coding))))
    (unless (string= old
                     (buffer-substring
                      (line-beginning-position) (line-end-position)))
      (signal 'wgrep-error "Buffer was changed after grep."))
    (cond
     (new
      (wgrep-replace-to-new-line new))
     (t
      ;; new nil means flush whole line.
      (wgrep-flush-pop-deleting-line)))))

;;;
;;; activate/deactivate marmalade install or github install.
;;;

;;;###autoload(add-hook 'grep-setup-hook 'wgrep-setup)
(add-hook 'grep-setup-hook 'wgrep-setup)

;; For `unload-feature'
(defun wgrep-unload-function ()
  (remove-hook 'grep-setup-hook 'wgrep-setup))

(provide 'wgrep)

;;; wgrep.el ends here
