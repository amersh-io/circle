;;;; Generations on disk.
;;;;
;;;;   DIRECTORY/
;;;;     session            the id of the conversation, as last known
;;;;     0/                 generation 0, built from source
;;;;       image            an executable SBCL image
;;;;       manifest.lisp    what it is; written last
;;;;     1/
;;;;       journal.lisp     the changes replayed on generation 0 to make it
;;;;       image
;;;;       manifest.lisp
;;;;       start-failed     present once it failed to start
;;;;
;;;; A generation can be started when its manifest says its replay passed
;;;; (or that it was built from source), its image is there and it has not
;;;; failed to start. The manifest is written last, after the image is in
;;;; place, so a generation interrupted while being made is never one.

(in-package #:circle/supervisor)

(defvar *generations-directory* (uiop:xdg-data-home "circle/")
  "Where generations live unless a directory is given: circle/ under the
user's data directory ($XDG_DATA_HOME, else ~/.local/share).")

(defun directory-of (directory)
  (uiop:ensure-directory-pathname (or directory *generations-directory*)))

(defun generation-directory (number &optional directory)
  "The directory of generation NUMBER in DIRECTORY."
  (merge-pathnames (format nil "~D/" number) (directory-of directory)))

(defun generation-file (number name &optional directory)
  "The file NAME of generation NUMBER in DIRECTORY, such as \"image\"."
  (merge-pathnames name (generation-directory number directory)))

(defun generation-numbers (&optional directory)
  "The numbers of the generations in DIRECTORY, whatever their state, in
increasing order."
  (sort (loop for sub in (uiop:subdirectories (directory-of directory))
              for name = (car (last (pathname-directory sub)))
              when (and (stringp name) (plusp (length name)) (every #'digit-char-p name))
                collect (parse-integer name))
        #'<))

(defun next-generation-number (&optional directory)
  "The number the next generation in DIRECTORY gets: one more than any
there, finished or not, so an interrupted one is never written over."
  (let ((numbers (generation-numbers directory)))
    (if numbers (1+ (car (last numbers))) 0)))

;;; Writing whole files

(defun write-file-atomically (pathname writer)
  "Call WRITER with an output stream to a new file, then put it at PATHNAME
in one rename, so PATHNAME is either as it was or the whole new file."
  (let ((temporary (make-pathname :name (format nil "~A.tmp-~D" (pathname-name pathname)
                                                (sb-posix:getpid))
                                  :defaults pathname)))
    (ensure-directories-exist pathname)
    (with-open-file (out temporary :direction :output :if-exists :supersede
                                   :external-format :utf-8)
      (funcall writer out)
      (finish-output out)
      (sb-posix:fsync (sb-sys:fd-stream-fd out)))
    (sb-posix:rename (uiop:native-namestring temporary) (uiop:native-namestring pathname))
    pathname))

(defun write-form (form out)
  (with-standard-io-syntax
    (let ((*package* (find-package :keyword))
          ;; Readably, SBCL writes a base string as #A((N) BASE-CHAR . "..."):
          ;; plain strings, numbers and keywords read back the same without it.
          (*print-readably* nil))
      (prin1 form out)
      (terpri out))))

(defun read-form-file (pathname)
  "The first form in PATHNAME, read without evaluation, or NIL if there is
none or it cannot be read."
  (ignore-errors
   (with-open-file (in pathname :if-does-not-exist nil :external-format :utf-8)
     (when in
       (with-standard-io-syntax
         (let ((*read-eval* nil)
               (*package* (find-package :keyword)))
           (read in nil nil)))))))

;;; Manifests

(defun read-manifest (number &optional directory)
  "The manifest of generation NUMBER, a property list, or NIL if it has
none yet."
  (let ((manifest (read-form-file (generation-file number "manifest.lisp" directory))))
    (and (listp manifest) manifest)))

(defun write-manifest (number manifest &optional directory)
  "Write MANIFEST, a property list of numbers, strings and keywords, as the
manifest of generation NUMBER."
  (write-file-atomically (generation-file number "manifest.lisp" directory)
                         (lambda (out) (write-form manifest out))))

(defun manifest-get (number key &optional directory)
  "The value of KEY in the manifest of generation NUMBER."
  (getf (read-manifest number directory) key))

;;; Which generation to start

(defun start-failed-p (number &optional directory)
  "True once generation NUMBER has failed to start."
  (and (probe-file (generation-file number "start-failed" directory)) t))

(defun mark-start-failed (number reason &optional directory)
  "Record that generation NUMBER failed to start, and why: it is not
started again."
  (write-file-atomically (generation-file number "start-failed" directory)
                         (lambda (out) (write-line reason out))))

(defun generation-startable-p (number &optional directory)
  "True if generation NUMBER can be started: its manifest says it passed its
replay or was built from source, its image is in place, and it has not
failed to start."
  (let ((manifest (read-manifest number directory)))
    (and manifest
         (eql number (getf manifest :number))
         (member (getf manifest :replay) '(:ok :base))
         (probe-file (generation-file number "image" directory))
         (not (start-failed-p number directory))
         t)))

(defun startable-generations (&optional directory)
  "The numbers of the generations in DIRECTORY that can be started, in
increasing order."
  (remove-if-not (lambda (number) (generation-startable-p number directory))
                 (generation-numbers directory)))

(defun newest-startable (&optional directory)
  "The number of the newest generation in DIRECTORY that can be started, or
NIL."
  (car (last (startable-generations directory))))

;;; The conversation

(defun read-session-id (&optional directory)
  "The id of the conversation the generations in DIRECTORY carry on, or NIL."
  (let ((id (read-form-file (merge-pathnames "session" (directory-of directory)))))
    (and (stringp id) (plusp (length id)) id)))

(defun write-session-id (id &optional directory)
  "Record ID as the conversation the generations in DIRECTORY carry on."
  (check-type id string)
  (write-file-atomically (merge-pathnames "session" (directory-of directory))
                         (lambda (out) (write-form id out))))
