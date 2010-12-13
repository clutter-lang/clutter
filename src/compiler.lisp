(in-package #:clutter)

(declaim (optimize debug))

(defstruct (split-val (:constructor split-val (llvm clutter)))
  llvm
  clutter)

(defvar *context* (llvm:global-context))
(defvar *module*)
(defvar *builder*)

(let ((llvm-inited nil))
 (defun init-llvm ()
   (unless llvm-inited
     (llvm:initialize-native-target)
     (setf llvm-inited t))))

(defun build-arith-op (name identity func args env)
  (reduce (rcurry (curry #'funcall func *builder*) name)
          args
          :key (rcurry #'compile-form env)
          :initial-value identity))

(defun build-prim-call (prim args env)
  (cond
    ((eq prim (cs "+")) (build-arith-op "sum" (llvm:const-int (llvm:int32-type) 0)
                                        #'llvm:build-add args env))
    ((eq prim (cs "-")) (if (> (length args) 1)
                            (build-arith-op "difference" (compile-form (first args) env)
                                            #'llvm:build-sub (rest args) env)
                            (llvm:build-neg *builder* (compile-form (first args) env) "negation")))
    ((eq prim (cs "*")) (build-arith-op "product" (llvm:const-int (llvm:int32-type) 1)
                                        #'llvm:build-mul args env))
    ((eq prim (cs "/")) (build-arith-op "product" (llvm:const-int (llvm:int32-type) 1)
                                        #'llvm:build-s-div args env))
    (t (error "Unsupported primitive: ~A" prim))))

(defun compile-form (form env)
  (typecase form
    (integer (llvm:const-int (llvm:int32-type) form))
    (clutter-symbol (llvm:build-load *builder* (split-val-llvm (lookup form env)) (clutter-symbol-name form)))
    (list
       (let ((cfunc (lookup (car form) env)))
         (if (primitive? (split-val-clutter cfunc))
             (build-prim-call (split-val-llvm cfunc) (rest form) env)
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

(defun compile-func (func env)
  (let* ((op (clutter-function-operator func))
         (args (clutter-operator-args op))
         (argtypes (make-array (length args) :initial-element (llvm:int32-type)))
         (ftype (llvm:function-type (llvm:int32-type) argtypes))
         (fobj (llvm:add-function *module* (clutter-symbol-name (clutter-operator-name op)) ftype))
         (fenv (make-env env)))
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
      (llvm:build-ret *builder* ret))
    (unless (llvm:verify-function fobj)
      (error "Invalid function ~A" func))))

(defun clone-env-tree (env)
  (let ((result (apply #'make-env (mapcar #'clone-env-tree (env-parents env)))))
    (mapenv (lambda (symbol value)
              (if (primitive? value)
                  (extend result symbol (split-val (combiner-name value) value))
                  (extend result symbol (split-val nil value))))
            env)
    result))

(defun clutter-compile (main &optional (output "binary"))
  "Write a binary to OUTPUT which invokes clutter function MAIN on execution."
  (init-llvm)
  (setf *module* (llvm:make-module output))
  (setf *builder* (llvm:make-builder))
  (unwind-protect
       (progn
         (compile-func main (clone-env-tree (clutter-operator-env (clutter-function-operator main))))
         (llvm:dump-module *module*)
         (llvm:write-bitcode-to-file *module* output))
    (llvm:dispose-module *module*)
    (llvm:dispose-builder *builder*)))
