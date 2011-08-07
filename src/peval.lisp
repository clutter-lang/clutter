(in-package :clutter)

(declaim (optimize (debug 3)))

(defvar *peval-prims* #+sbcl (make-hash-table :test 'eq :weakness :key)
                      #+ccl  (make-hash-table :test 'eq :weak t)
  "Mapping from interpreter Clutter functions to primitive partial evaluation functions.")

(defstruct (dynamic (:constructor make-dynamic (form)))
  form)

(defmethod print-object ((o dynamic) s)
  (print-unreadable-object (o s :type t)
    (format s "~A" (dynamic-form o))))

(defun dynamic? (value)
  (typep value 'dynamic))

(defun static? (value)
  (not (dynamic? value)))

(defun staticify (value)
  (if (dynamic? value)
      (dynamic-form value)
      (list (lookup (cs "quote")) value)))

(defun peval-prim? (combiner)
  (nth-value 1 (gethash combiner *peval-prims*)))

(defun pevaluator (combiner)
  (multiple-value-bind (value exists) (gethash combiner *peval-prims*)
    (if exists
        value
        (error "~A is not a peval primitive!" combiner))))

(defun (setf pevaluator) (value combiner)
  (setf (gethash combiner *peval-prims*) value))

(defmacro def-peval-prim (name args &body body)
  `(setf (pevaluator (lookup (cs ,name) *global-env*)) (lambda ,args ,@body)))

(defmacro def-peval-prim-op (name env-var args &body body)
  `(setf (pevaluator (lookup (cs ,name) *global-env*)) (lambda ,(cons env-var args) ,@body)))

(def-peval-prim "eval" (form env)
  (peval form env))

(def-peval-prim-op "nlambda" denv (name args &rest body &aux (fake-env (make-env denv)))
  (mapc (lambda (arg)
          (extend fake-env arg (make-dynamic arg)))
        args)
  (clutter-eval
   (list*
    (lookup (cs "nlambda"))
    name args
    (nsubst (list (lookup (cs "get-current-env")))
            (list (lookup (cs "quote")) fake-env)
            (mapcar (compose #'staticify (rcurry #'peval fake-env)) body)
            :test #'equal))
   denv))

(def-peval-prim-op "if" denv (condition-form then-form else-form)
  (let ((condition (peval condition-form denv))
        (then (peval then-form denv))
        (else (peval else-form denv)))
    (if (static? condition)
        (if (eq condition *false*)
            else
            then)
        (make-dynamic (list (lookup (cs "if")) (staticify condition) (staticify then) (staticify else))))))

(def-peval-prim-op "set-in!" denv (target-env-form var value-form)
  (make-dynamic (list (lookup (cs "set-in!")) (staticify (peval target-env-form denv)) var (staticify (peval value-form denv)))))

(def-peval-prim-op "def-in!" denv (target-env-form var value-form)
  (make-dynamic (list (lookup (cs "def-in!")) (staticify (peval target-env-form denv)) var (staticify (peval value-form denv)))))

(def-peval-prim-op "def-const-in!" denv (target-env-form var value-form)
  (make-dynamic (list (lookup (cs "def-const-in!")) (staticify (peval target-env-form denv)) var (staticify (peval value-form denv)))))

(defun peval (form &optional (env *global-env*))
  (typecase form
    (list (peval-combiner form env))
    (clutter-symbol (peval-symbol form env))
    (t form)))

(defun peval-symbol (symbol env)
  (if (eq symbol *ignore*)
      *ignore*
      (multiple-value-bind (value mutable binding-env) (lookup symbol env)
        (declare (ignore binding-env))
        (if mutable
            (make-dynamic symbol)
            value))))

(defun peval-combiner (form env)
  (destructuring-bind (combiner-form &rest arg-forms) form
    (let* ((combiner (peval combiner-form env))
           (primitive (peval-prim? combiner)))
     (typecase combiner
       (clutter-operative
        (if primitive
            (apply (pevaluator combiner) env arg-forms)
            (inline-op combiner arg-forms env)))
       (clutter-function
        (let ((args (mapcar (rcurry #'peval env) arg-forms)))
         (cond
           (primitive
            (apply (pevaluator combiner) args))
           ((and (clutter-operative-pure (clutter-function-operative combiner))
                 (every #'static? args))
            (clutter-eval (cons (clutter-function-operative combiner) args)))
           (t
            (make-dynamic (list* combiner (mapcar #'staticify args)))))))
       (t (error "Tried to invoke ~A, which is not a combiner" combiner))))))

(defun inline-op (operative args env &aux (inline-env (make-env (clutter-operative-env operative))))
  (mapc (rcurry (curry #'extend inline-env) nil)
        (list* (clutter-operative-denv-var operative) (clutter-operative-args operative))
        (list* env args))
  (let ((body (subst (clutter-operative-env operative) inline-env
                     (mapcar (rcurry #'peval inline-env) (clutter-operative-body operative)))))
    (if (> (length body) 1)
        (list* (lookup (cs "do")) body)
        (first body))))
