;;;; Changes the image keeps, and checks they must pass.
;;;;
;;;; A change is Lisp source text and the package to read it in, as the
;;;; model gave it to eval: it is replayed by reading that text again, so
;;;; it means the same as it did. A check is source too, run after all the
;;;; changes; it must return true. Checks stay with the generations that
;;;; follow, so every later replay runs them again.

(in-package #:circle/generation)

(defvar *pending* '()
  "The changes and checks noted since the image's generation, newest first.")

(defvar *pending-lock* (sb-thread:make-mutex :name "circle pending changes"))

(defvar *checks* '()
  "The checks the image's generation and those before it passed, oldest
first.")

(defvar *replaying* nil
  "True while a fresh process replays a journal.")

(defun source-text (source package)
  "SOURCE as text: a string as it is, a form printed to be read back in
PACKAGE."
  (if (stringp source)
      source
      (with-standard-io-syntax
        (let ((*package* package)
              (*print-readably* t))
          (prin1-to-string source)))))

(defun entry-package (package)
  (or (find-package package)
      (error "No package named ~A." package)))

(defun evaluate-source (source package)
  "Read the forms in SOURCE in PACKAGE, with *READ-EVAL* false, and
evaluate them in order; return the values of the last."
  (let ((*package* (entry-package package))
        (values '()))
    (with-input-from-string (in source)
      (loop for form = (let ((*read-eval* nil)) (read in nil in))
            until (eq form in)
            do (setf values (multiple-value-list (eval form)))))
    (values-list values)))

(defun add-pending (entry)
  (sb-thread:with-mutex (*pending-lock*)
    (push entry *pending*))
  entry)

(defun note-change (source &key (package *package*))
  "Note SOURCE -- a string of forms, or a form -- as a change to keep: the
next freeze replays it, read in PACKAGE, on a fresh copy of this image's
generation. Note a change after evaluating it here; it is not evaluated
again in this image. Return the change, a property list."
  (let ((package (entry-package package)))
    (if *replaying*
        nil
        (add-pending (list :kind :change :package (package-name package)
                           :source (source-text source package))))))

(defun note-check (source &key (package *package*))
  "Note SOURCE, forms read in PACKAGE whose last value must be true, as a
check: it runs now, here, and must pass; it runs again in every replay from
the next freeze on. Return the check, a property list."
  (let* ((package (entry-package package))
         (entry (list :kind :check :package (package-name package)
                      :source (source-text source package))))
    (cond (*replaying*
           ;; A check noted by a change that is being replayed.
           (setf *checks* (append *checks* (list entry))))
          ((evaluate-source (getf entry :source) package)
           (add-pending entry))
          (t (error "The check ~A is false in this image." (getf entry :source))))))

(defun pending-changes ()
  "The changes and checks noted since this image's generation, oldest
first, each a property list (:KIND :CHANGE or :CHECK, :PACKAGE, :SOURCE)."
  (sb-thread:with-mutex (*pending-lock*)
    (reverse *pending*)))

(defun discard-pending-changes ()
  "Forget the changes and checks noted since this image's generation; they
stay in this image but will not be frozen."
  (sb-thread:with-mutex (*pending-lock*)
    (setf *pending* '())))

(defun generation-checks ()
  "The checks this image's generation passed, oldest first, each a property
list like the entries of PENDING-CHANGES."
  *checks*)

(defun forget-frozen (entries)
  "ENTRIES are in a generation now: drop them from the pending ones and keep
their checks."
  (sb-thread:with-mutex (*pending-lock*)
    (setf *pending* (remove-if (lambda (entry) (member entry entries :test #'eq)) *pending*)))
  (setf *checks* (append *checks* (remove :change entries :key (lambda (e) (getf e :kind))))))

;;; Journals

(defun write-journal (pathname entries number)
  (write-file-atomically
   pathname
   (lambda (out)
     (format out ";;;; circle generation ~D: the changes and checks replayed to make it.~%"
             number)
     (with-standard-io-syntax
       (let ((*package* (find-package :keyword))
             (*print-readably* nil))
         (dolist (entry entries)
           (prin1 entry out)
           (terpri out)))))))

(defun read-journal (pathname)
  "The entries of the journal at PATHNAME, read without evaluation."
  (with-open-file (in pathname :external-format :utf-8)
    (with-standard-io-syntax
      (let ((*read-eval* nil)
            (*package* (find-package :keyword)))
        (loop for entry = (read in nil in)
              until (eq entry in)
              collect entry)))))

;;; The eval tool keeps changes here.

(setf *keep-function*
      (lambda (code package) (note-change code :package package)))
