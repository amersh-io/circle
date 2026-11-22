(in-package #:circle/test)

(defun run! ()
  "Run every test; signal an error if any of them fails."
  (setf *failures* '() *passed* 0)
  (uiop:with-temporary-file (:pathname marker :prefix "circle-test")
    ;; Set, not bound: the window checks run on a thread of their own, which
    ;; sees global values only.
    (let ((previous *fake-state*))
      (setf *fake-state* (uiop:ensure-directory-pathname
                          (merge-pathnames (format nil "~A.d" (file-namestring marker))
                                           (uiop:pathname-directory-pathname marker)))
            (uiop:getenv "CIRCLE_FAKE_STATE") (uiop:native-namestring *fake-state*))
      (unwind-protect
           (progn
             (tool-checks)
             (engine-checks)
             (generations-suite)
             (interface-unit-checks)
             #+darwin (window-suite)
             (example-checks)
             (claude-checks))
        (uiop:delete-directory-tree *fake-state* :validate t :if-does-not-exist :ignore)
        (setf *fake-state* previous))))
  (format t "~&~D passed, ~D failed~%" *passed* (length *failures*))
  (when *failures*
    (error "~D circle test~:P failed: ~{~A~^, ~}"
           (length *failures*) (reverse *failures*)))
  t)
