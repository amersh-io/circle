;;;; Ask Claude one question from a Lisp image and print the answer.
;;;;
;;;;   sbcl --load .qlot/setup.lisp --eval '(asdf:load-system "circle")' \
;;;;        --load examples/hello.lisp

(in-package #:cl-user)

(circle:with-engine (engine (circle:make-engine :model "haiku"))
  (format t "~A~%" (circle:ask engine "What is the sum of the squares of 3 and 4?")))
