;;;; Every example in examples/ runs in a child Lisp against the stand-in
;;;; CLI, named by *CLAUDE-COMMAND*.

(in-package #:circle/test)

(defun run-example (name)
  "Run examples/NAME.lisp in a fresh Lisp; return its output and exit code."
  (multiple-value-bind (output error-output code)
      (uiop:run-program
       (list (uiop:native-namestring sb-ext:*runtime-pathname*)
             "--noinform" "--non-interactive" "--no-userinit"
             "--load" (root ".qlot/setup.lisp")
             "--eval" (format nil "(asdf:load-asd ~S)" (root "circle.asd"))
             "--eval" "(asdf:load-system \"circle\")"
             "--eval" (format nil "(setf circle:*claude-command* '~S)" (fake-command))
             "--load" (root (format nil "examples/~A.lisp" name)))
       :output :string :error-output :string :ignore-error-status t)
    (values (concatenate 'string output error-output) code)))

(defun example-checks ()
  (check "examples/hello.lisp asks a question and prints the answer"
         (multiple-value-bind (output code) (run-example "hello")
           (and (eql 0 code)
                (says output "echo: What is the sum of the squares of 3 and 4?"))))
  (check "examples/generations.lisp builds generation 0 and runs it once"
         (multiple-value-bind (output code) (run-example "generations")
           (and (eql 0 code)
                (says output "circle: generation 0 ready")
                (says output "echo: Say hello in five words."))))
  (check "examples/window.lisp shows a conversation's transcript, with or without a window"
         (multiple-value-bind (output code) (run-example "window")
           (and (eql 0 code)
                (says output "user: What is the sum of the squares of 3 and 4?")
                (says output "assistant: echo: What is the sum of the squares of 3 and 4?")))))
