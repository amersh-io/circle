;;;; Test harness for circle. Run with (asdf:test-system "circle").

(defpackage #:circle/test
  (:use #:cl #:circle)
  (:export #:run!))

(in-package #:circle/test)

(defvar *failures* '())
(defvar *passed* 0)

(defun selected-p (name)
  "True unless CIRCLE_TEST_ONLY names text that NAME does not contain."
  (let ((only (uiop:getenv "CIRCLE_TEST_ONLY")))
    (or (null only) (zerop (length only)) (search only name))))

(defmacro check (name form)
  "Evaluate FORM as the check NAME, unless it is not selected; record a
failure if it returns NIL or signals an error."
  (let ((n (gensym "NAME")))
    `(let ((,n ,name))
       (when (selected-p ,n)
         (handler-case
             (if ,form
                 (progn (incf *passed*) (format t "~&ok    ~A~%" ,n))
                 (progn (push ,n *failures*) (format t "~&FAIL  ~A~%" ,n)))
           (error (e)
             (push ,n *failures*)
             (format t "~&FAIL  ~A: ~A~%" ,n e)))))))

(defun root (relative)
  "The native namestring of RELATIVE in the repository."
  (uiop:native-namestring (asdf:system-relative-pathname "circle" relative)))

(defun says (text expected)
  "True if TEXT contains EXPECTED; otherwise print TEXT and return NIL."
  (or (and (stringp text) (search expected text))
      (progn (format t "~&;; expected ~S in:~%~A~%" expected text) nil)))
