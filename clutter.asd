;;;; -*- Mode: Lisp; indent-tabs-mode: nil -*-

(defsystem clutter
  :serial t
  :components
  ((:module "src"
            :serial t
            :components
            ((:file "cl-package")
             (:file "environments")
             (:file "functions")
             (:file "eval")
             (:file "repl")
             (:file "primitives")))))

