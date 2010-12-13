(in-package #:clutter)

(declaim (optimize debug))

(defstruct (split-val (:constructor split-val (llvm clutter)))
  llvm
  clutter)

(defvar *context* (llvm:global-context))
(defvar *module*)
(defvar *builder*)

(defvar *compiler-prims* (make-hash-table :test 'eq))
(defun compiler-prim? (clutter-val)
  (nth-value 1 (gethash clutter-val *compiler-prims*)))
(defmacro def-compiler-primop (name env-var lambda-list &body body)
  `(setf (gethash (lookup (cs ,name)) *compiler-prims*) #'(lambda ,(cons env-var lambda-list) ,@body)))
(defmacro def-compiler-primfun (name lambda-list &body body)
  (let ((env-var (gensym "ENV"))
        (args (gensym "ARGS")))
   `(setf (gethash (lookup (cs ,name)) *compiler-prims*)
          #'(lambda (,env-var &rest ,args)
              (apply (lambda ,lambda-list ,@body) (mapcar (rcurry #'compile-form ,env-var)
                                                          ,args))))))

(defun build-prim-call (prim args env)
  (let ((primbuilder (gethash prim *compiler-prims*)))
    (if primbuilder
        (apply primbuilder env args)
        (error "Unsupported primitive: ~A" prim))))

;;; Control
(def-compiler-primop "if" env (condition true-form false-form)
  (let* ((prev-block (llvm:insertion-block *builder*))
         (func (llvm:basic-block-parent prev-block))
         (true-block (llvm:append-basic-block func "if-true"))
         (false-block (llvm:append-basic-block func "if-false"))
         (continue-block (llvm:append-basic-block func "if-continue"))
         (return-value))
    (llvm:position-builder-at-end *builder* prev-block)
    (llvm:build-cond-br *builder*
                         (llvm:build-trunc *builder* (compile-form condition env) (llvm:int1-type) "boolean")
                         true-block
                         false-block)
    (llvm:position-builder-at-end *builder* continue-block)
    (setf return-value (llvm:build-phi *builder* (llvm:int32-type) "if-result"))

    (llvm:position-builder-at-end *builder* true-block)
    ;; Get insert block in case true-form contains other blocks
    (llvm:add-incoming return-value
                       (vector (compile-form true-form env))
                       (vector (llvm:insertion-block *builder*)))
    (llvm:build-br *builder* continue-block)

    (llvm:position-builder-at-end *builder* false-block)
    ;; Get insert block in case false-form contains other blocks
    (llvm:add-incoming return-value
                       (vector (compile-form false-form env))
                       (vector (llvm:insertion-block *builder*)))
    (llvm:build-br *builder* continue-block)
    
    (llvm:position-builder-at-end *builder* continue-block)
    return-value))

;;; Arithmetic
(defun build-arith-op (name initial func args)
  (reduce (rcurry (curry #'funcall func *builder*) name)
          args
          :initial-value initial))
(def-compiler-primfun "+" (first &rest args)
  (build-arith-op "sum" first #'llvm:build-add args))
(def-compiler-primfun "-" (first &rest args)
  (if args
      (build-arith-op "difference" first #'llvm:build-sub (rest args))
      (llvm:build-neg *builder* first "negation")))
(def-compiler-primfun "*" (first &rest args)
  (build-arith-op "product" first #'llvm:build-mul args))
(def-compiler-primfun "/" (first &rest args)
  (build-arith-op "product" first #'llvm:build-s-div args))

;;; Arithmetic comparison
(def-compiler-primfun "=?" (a b)
  (llvm:build-i-cmp *builder* := a b "equality"))

(defun compile-form (form env)
  (typecase form
    (integer (llvm:const-int (llvm:int32-type) form))
    (clutter-symbol (llvm:build-load *builder* (or (split-val-llvm (lookup form env)) (error "No binding for: ~A" form)) (clutter-symbol-name form)))
    (list
       (let ((cfunc (lookup (car form) env)))
         (if (primitive? (split-val-clutter cfunc))
             (build-prim-call (split-val-clutter cfunc) (rest form) env)
             (progn
               ;; Ensure that the function has been compiled.
               ;; TODO: Ensure that *the relevant specialization* has been.
               (unless (split-val-llvm cfunc)
                 (setf (split-val-llvm cfunc)
                       (compile-func (split-val-clutter cfunc) env)))
               (llvm:build-call *builder* (split-val-llvm cfunc)
                                (make-array (length (rest form))
                                            :initial-contents (mapcar (rcurry #'compile-form env)
                                                                      (rest form)))
                                "")))))))

(defun compile-func (split env)
  (let* ((op (clutter-function-operator (split-val-clutter split)))
         (args (clutter-operator-args op))
         (argtypes (make-array (length args) :initial-element (llvm:int32-type)))
         (ftype (llvm:function-type (llvm:int32-type) argtypes))
         (fobj (llvm:add-function *module* (clutter-symbol-name (clutter-operator-name op)) ftype))
         (fenv (make-env env)))
    (setf (split-val-llvm split) fobj)
    (llvm:position-builder-at-end *builder*
                                  (llvm:append-basic-block fobj "entry"))
    (mapc (lambda (arg name)
            (setf (llvm:value-name arg) (clutter-symbol-name name))
            (extend fenv name
                    (split-val (llvm:build-alloca *builder* (llvm:type-of arg) (clutter-symbol-name name))
                               nil))
            (llvm:build-store *builder* arg (split-val-llvm (lookup name fenv))))
          (llvm:params fobj)
          args)
    (let ((ret))
      (mapc (compose (lambda (x) (setf ret x))
                     (rcurry #'compile-form fenv))
            (clutter-operator-body op))
      (llvm:build-ret *builder* (llvm:build-int-cast *builder* ret (llvm:int32-type) "ret")))))

(defun clone-env-tree (env)
  (let ((result (apply #'make-env (mapcar #'clone-env-tree (env-parents env)))))
    (mapenv (lambda (symbol value)
              (cond
                ((compiler-prim? value)
                 (extend result symbol (split-val (combiner-name value) value)))
                ((primitive? value)
                 ;; (warn "Unsupported primitive: ~A" value)
                 )
                (t (extend result symbol (split-val nil value)))))
            env)
    result))

(let ((llvm-inited nil))
 (defun init-llvm ()
   (unless llvm-inited
     (llvm:initialize-native-target)
     (setf llvm-inited t))))

(defun clutter-compile (func-name env &optional (output "binary"))
  "Write compiled code, which invokes clutter function named FUNC-NAME in ENV on execution, to OUTPUT."
  (init-llvm)
  (setf *module* (llvm:make-module output))
  (setf *builder* (llvm:make-builder))
  (unwind-protect
       (let ((env (clone-env-tree env)))
         (compile-func (lookup func-name env) env)
         (llvm:dump-module *module*)
         (unless (llvm:verify-module *module*)
           (llvm:write-bitcode-to-file *module* output)))
    (llvm:dispose-module *module*)
    (llvm:dispose-builder *builder*)))
