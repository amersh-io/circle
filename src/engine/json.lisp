;;;; JSON values, as the engine reads and writes them.
;;;;
;;;; An object is an EQUAL hash table keyed by strings, an array a vector,
;;;; true is T, false is NIL and null is the symbol NULL. Writing also takes
;;;; a list as an array. The text is read and written by com.inuoe.jzon.

(in-package #:circle/engine)

(defun parse-json (text)
  "The value of the JSON TEXT."
  (com.inuoe.jzon:parse text))

(defun to-json (value)
  "The JSON text of VALUE, on one line."
  (com.inuoe.jzon:stringify value))

(defun json-object (&rest keys-and-values)
  "A JSON object of KEYS-AND-VALUES, alternating strings and values. A key
whose value is :ABSENT is left out."
  (let ((object (make-hash-table :test 'equal)))
    (loop for (key value) on keys-and-values by #'cddr
          unless (eq value :absent)
            do (setf (gethash (string key) object) value))
    object))

(defun json-get (value &rest path)
  "Follow PATH, strings for object keys and integers for array indices,
from VALUE; NIL where a step is missing."
  (dolist (step path value)
    (setf value
          (typecase step
            (string (and (hash-table-p value) (values (gethash step value))))
            (integer (and (vectorp value) (not (stringp value))
                          (< -1 step (length value)) (aref value step)))
            (t (error "~S is not a JSON path step." step))))))
