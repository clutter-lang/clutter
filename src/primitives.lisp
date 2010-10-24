;;;; -*- Mode: Lisp; indent-tabs-mode: nil -*-

(in-package #:clutter)

(declaim (optimize debug))

;;;
;;; Primitive Constants
;;;

(defparameter *true* (cs "#t"))
(defparameter *false* (cs "#f"))

;;;
;;; Primitive functions
;;;

(defmacro defprimitive (name value)
  `(extend *global-env* (cs "fun") (clutter-symbol ,name) ,value))

(defmacro defprimop (name vau-list &body body)
  `(defprimitive ,name
       (make-clutter-operator
        :name ,name
        :function (lambda ,vau-list ,@body))))

(defmacro defprimfun (name vau-list &body body)
  `(defprimitive ,name
       (make-function
        (make-clutter-operator
         :name ,name
         :function (lambda (*denv* ,@vau-list)
                     ,@body)))))

(defprimop "vau" (static-env env-var vau-list &rest body)
  (make-clutter-operator
   :function
   (lambda (*denv* &rest values)
     (multiple-value-bind (required optional rest)
         (parse-vau-list vau-list)
       (declare (ignore optional))
       (unless (or (= (length values) (length vau-list))
                   (and rest (>= (length values) (1- (length vau-list))))
                   (error "Wrong number of arguments")))
       (let ((env (make-env static-env)))
         (loop for var in (list* env-var rest required)
               for value in (list* *denv*
                                   (nthcdr (length required) values)
                                   (subseq values 0 (length required)))
               do (extend env (cs "var") var value))
         (loop for sexp in body
               for last-value = (clutter-eval sexp env)
               finally (return last-value)))))))

(defprimfun "wrap" (operative)
  (make-function operative))

(defprimfun "unwrap" (function)
  (clutter-function-operator function))

(defprimfun "eval" (expression environment &optional (subenv (cs "var")))
  (clutter-eval expression environment subenv))

(defprimop "lookup" (*denv* subenv symbol environment)
  (lookup subenv symbol (clutter-eval environment *denv*)))

(defprimop "set-lookup!" (*denv* value subenv symbol environment)
  (setf (lookup subenv symbol (clutter-eval environment *denv*)) (clutter-eval value *denv*)))

(defprimop "def-lookup!" (*denv* value subenv symbol environment)
  (extend (clutter-eval environment *denv*) subenv symbol (clutter-eval value *denv*)))

(defprimfun "make-env" (&optional parent)
  (make-env parent))

(defprimop "direct-set!" (*denv* subenv var value)
  (setf (lookup subenv var *denv*) (clutter-eval value *denv*)))

(defprimop "direct-def!" (*denv* subenv var value)
  (extend *denv* subenv var (clutter-eval value *denv*))
  var)

(defun clutter-true-p (exp)
  (not (eq exp *false*)))

(defprimop "if" (*denv* test if-true if-false)
  (if (clutter-true-p (clutter-eval test *denv*))
      (clutter-eval if-true *denv*)
      (clutter-eval if-false *denv*)))

(defprimop "symbolize!" (*denv* var value)
  (let ((val (clutter-eval value *denv*)))
    (assert (clutter-operator-p val))
    (extend *denv* (cs "var") var (make-symbol-operator val))))

(defprimfun "symbolize" (&rest values)
  (assert (clutter-operator-p (car values)))
  (make-symbol-operator (car values)))

(defprimfun "not" (x)
  (if (eq x *false*) *true* *false*))
(defprimfun "null?" (x)
  (if (eq x nil) *true* *false*))

(defprimfun "cons" (x y)
  (cons x y))
(defprimfun "cons?" (x)
  (consp x))
(defprimfun "car" (cons)
  (car cons))
(defprimfun "cdr" (cons)
  (cdr cons))
(defprimfun "list" (&rest values)
  values)
(defprimfun "list*" (&rest values)
  (apply #'list* values))
(defprimfun "length" (seq)
  (length seq))

(defprimfun "set-head" (cons new-car)
  (rplaca cons new-car))
(defprimfun "set-tail" (cons new-cdr)
  (rplacd cons new-cdr))

(defprimfun "eql?" (x y)
  (if (eql x y) *true* *false*))

(defprimfun "symbol?" (x)
  (if (clutter-symbol-p x) *true* *false*))
(defprimfun "number?" (x)
  (numberp x))

(defprimfun "<?" (x y)
  (if (< x y) *true* *false*))
(defprimfun ">?" (x y)
  (if (> x y) *true* *false*))
(defprimfun "<=?" (x y)
  (if (<= x y) *true* *false*))
(defprimfun ">=?" (x y)
  (if (>= x y) *true* *false*))
(defprimfun "=?" (x y)
  (if (= x y) *true* *false*))
(defprimfun "+" (&rest values)
  (apply #'+ values))
(defprimfun "-" (number &rest more-numbers)
  (apply #'- number more-numbers))
(defprimfun "*" (&rest values)
  (apply #'* values))
(defprimfun "/" (number &rest more-numbers)
  (apply #'/ number more-numbers))

(defprimfun "print" (obj)
  (print obj))

;;; For escaping the REPL cleanly.
(define-condition quit () ())
(defprimfun "quit" ()
  (signal (make-condition 'quit)))
