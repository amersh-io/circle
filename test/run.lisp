(in-package #:circle/test)

(defun run! ()
  "Run every test; signal an error if any of them fails."
  (setf *failures* '() *passed* 0)
  (uiop:with-temporary-file (:pathname marker :prefix "circle-test")
    (let ((*fake-state* (uiop:ensure-directory-pathname
                         (merge-pathnames (format nil "~A.d" (file-namestring marker))
                                          (uiop:pathname-directory-pathname marker)))))
      (setf (uiop:getenv "CIRCLE_FAKE_STATE") (uiop:native-namestring *fake-state*))
      (unwind-protect
           (progn
             (tool-checks)
             (engine-checks)
             (generations-suite)
             (example-checks)
             (claude-checks))
        (uiop:delete-directory-tree *fake-state* :validate t :if-does-not-exist :ignore))))
  (format t "~&~D passed, ~D failed~%" *passed* (length *failures*))
  (when *failures*
    (error "~D circle test~:P failed: ~{~A~^, ~}"
           (length *failures*) (reverse *failures*)))
  t)
