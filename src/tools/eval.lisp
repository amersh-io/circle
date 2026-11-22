;;;; eval: the model's way into the running image.

(in-package #:circle/tools)

(defvar *eval-package* "CL-USER"
  "The package the eval tool reads in when the model names none.")

(defvar *keep-function* nil
  "Called with the code and the package name of a successful eval the model
asked to keep, or NIL where nothing is kept. circle/generation sets it to
note the code as a change for the next generation.")

(defvar *eval-output-limit* 50000
  "The most characters of printed output and values the eval tool answers
with; the rest is cut and said to be.")

(defun limit-text (text)
  (if (> (length text) *eval-output-limit*)
      (format nil "~A~%;; ... ~D more characters cut" (subseq text 0 *eval-output-limit*)
              (- (length text) *eval-output-limit*))
      text))

(defun eval-forms (code &key (package *eval-package*))
  "Read the forms in CODE, a string, in PACKAGE with *READ-EVAL* false, and
evaluate them one after another in this image. Return the text the model
reads: what they printed, then the values of the last form, one per line
after =>. An error stops there and signals TOOL-ERROR with the output so
far, the error and the innermost frames of its backtrace."
  (let ((package (or (find-package package)
                     (error 'tool-error :message (format nil "No package named ~A." package))))
        (output (make-string-output-stream))
        (values '()))
    (flet ((answer (&optional problem)
             (let ((printed (get-output-stream-string output)))
               (limit-text
                (with-output-to-string (s)
                  (when (plusp (length printed))
                    (write-string printed s)
                    (fresh-line s))
                  (if problem
                      (write-string problem s)
                      (format s "~:[; no values~;~:*~{=> ~S~^~%~}~]" values)))))))
      (let ((problem
              (block evaluate
                (let ((*package* package)
                      (*standard-output* output)
                      (*error-output* output)
                      (*trace-output* output))
                  (handler-bind
                      ((serious-condition
                         (lambda (condition)
                           (return-from evaluate
                             (with-output-to-string (s)
                               (format s "~A: ~A~%Backtrace:~%" (type-of condition) condition)
                               (sb-debug:print-backtrace :count 12 :stream s))))))
                    (with-input-from-string (in code)
                      (loop for form = (let ((*read-eval* nil)) (read in nil in))
                            until (eq form in)
                            do (setf values (multiple-value-list (eval form)))))))
                nil)))
        (if problem
            (error 'tool-error :message (answer problem))
            (answer))))))

(define-tool eval ((code :string "Common Lisp forms to read and evaluate, in order.")
                   &optional
                   (package :string "The package to read them in; CL-USER if left out.")
                   (keep :boolean "True if these forms change the image in a way to keep: once they have run without error they are noted as a change, which freeze_generation replays into the next generation. Leave it out for anything else."))
  "Evaluate Common Lisp forms in the running SBCL image this conversation
lives in, and answer with what they printed and the values of the last one.
Definitions stay in the image: a function defined here can be called by the
next eval. An error is answered with its backtrace."
  (let* ((package (or package *eval-package*))
         (answer (eval-forms code :package package)))
    (cond ((not keep) answer)
          (*keep-function*
           (funcall *keep-function* code package)
           (format nil "~A~%;; kept as a change for the next generation" answer))
          (t (format nil "~A~%;; not kept: this image keeps no generations" answer)))))
