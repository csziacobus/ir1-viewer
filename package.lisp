;;;; package.lisp

(defpackage #:ir1-viewer
  (:use #:clim-lisp #:clim #:closer-mop)
  (:shadowing-import-from #:closer-mop
                          #:standard-generic-function
                          #:defclass
                          #:defmethod
                          #:defgeneric)
  (:import-from #:sb-c
		#:awhen #:it
		#:symbolicate
		#:with-unique-names)
  (:import-from #:sb-ext
		#:unlock-package)
  (:export #:view
	   #:dump))

