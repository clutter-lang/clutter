;;;; -*- Mode: Lisp; indent-tabs-mode: nil -*-

(defpackage #:fexpr-clutter (:use :cl :alexandria :anaphora))
(in-package #:fexpr-clutter)

(defstruct env
  parent bindings)

(defun clutter-eval (expression &optional (environment *global-env*))
  (cond ((symbolp expression) (eval/symbol expression environment))
        ((consp expression) (eval/combiner expression environment))
        (t expression)))

(defun eval/symbol (symbol env)
  (lookup symbol env))

(defun eval/combiner (expression env)
  (let ((f (clutter-eval (car expression) env)))
    (if (clutter-operator-p f)
        (invoke f env (cdr expression))
        (error "Not an operator: ~A." f))))

(defun lookup (symbol &optional (env *global-env*))
  (if env
      (or (gethash symbol (env-bindings env))
          (lookup symbol (env-parent env)))
      (error "No binding for ~A." symbol)))

(defun (setf lookup) (new-value symbol env)
  (if env
      (if (gethash symbol (env-bindings env))
          (setf (gethash symbol (env-bindings env)) new-value)
          (setf (lookup symbol (env-parent env)) new-value))
      (error "No binding for ~A." symbol)))

(defun extend (env symbol value)
  (if (nth-value 1 (gethash symbol (env-bindings env)))
      (warn "Redefinition of ~A." symbol))
  (setf (gethash symbol (env-bindings env)) value))

(defun make-child-env (env variables values)
  (make-env :parent env
            :bindings (aprog1 (make-hash-table :test 'eq)
                        (mapc (lambda (name value)
                                (setf (gethash name it) value))
                              variables values))))

(defvar *denv* nil)
(defstruct clutter-operator function)
(defun make-operator (variables body env)
  (make-clutter-operator 
   :function
   (lambda (*denv* values)
     (let ((env (make-child-env env variables values)))
       (loop for sexp in body
          for last-value = (clutter-eval sexp env)
          finally (return last-value))))))

(defun get-current-env () *denv*)

(defun invoke (operator env args)
  (if (clutter-operator-p operator)
      (funcall (clutter-operator-function operator) env args)
      (error "Not a function: ~A." operator)))

(defparameter *global-env*
  (make-env
   :parent nil
   :bindings
   (alist-hash-table 
    (list (cons '+ (make-clutter-operator
                    :function (lambda (*denv* values)
                                (reduce #'+ (mapcar (rcurry #'clutter-eval *denv*)
                                                    values)))))
          (cons 'car (make-clutter-operator
                      :function (lambda (*denv* values)
                                  (car (clutter-eval (car values) *denv*)))))
          (cons 'eval (make-clutter-operator
                       :function (lambda (*denv* values)
                                   (let ((values (mapcar (rcurry #'clutter-eval *denv*)
                                                         values)))
                                     (clutter-eval (first values) (second values))))))
          (cons 'get-current-env
                (make-clutter-operator
                 :function (lambda (*denv* values)
                             (declare (ignore values))
                             *denv*)))
          (cons 'vau
                (make-clutter-operator
                 :function (lambda (static-env values)
                             (destructuring-bind (env-var lambda-var &rest body)
                                 values
                               (make-clutter-operator
                                :function
                                (lambda (*denv* values)
                                  (let ((env (make-child-env static-env
                                                     (list env-var lambda-var)
                                                     (list *denv* values))))
                                    (loop for sexp in body
                                          for last-value = (clutter-eval sexp env)
                                          finally (return last-value))))))))))
    :test 'eq)))
