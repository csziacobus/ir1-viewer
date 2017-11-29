;;;; ir1-viewer.lisp

(in-package #:ir1-viewer)

;;; "ir1-viewer" goes here. Hacks and glory await!

(defclass flow-view (gadget-view) ())
(defparameter +flow-view+ (make-instance 'flow-view))

;;; Flow Stuffs
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((display (xlib::open-default-display)))
    (defvar *screen-width* (xlib::screen-width (xlib::display-default-screen display)))
    (defvar *screen-height* (xlib::screen-height (xlib::display-default-screen display)))
    (xlib::close-display display)))

(defvar *flow-width* (/ *screen-width* 2))
(defvar *flow-height* *screen-height*)

(defvar *flow-unit* (/ *screen-width* 40))

(defvar *flow-x-spacing* *flow-unit*)
(defvar *flow-y-spacing* *flow-unit*)
(defvar *flow-block-x-spacing* (* 2 *flow-x-spacing*))
(defvar *flow-block-y-spacing* *flow-y-spacing*)

(defparameter *flow-lvar-x-spacing-ratio* 3)

(defparameter *flow-margin-ratio-x* 1)
(defparameter *flow-margin-ratio-y* 1)
(defparameter *flow-clambda-margin-ratio-x* 1/3)
(defparameter *flow-clambda-margin-ratio-y* 1/3)
(defparameter *flow-block-margin-ratio-x* 2)
(defparameter *flow-block-margin-ratio-y* 0)

(defvar *copy-of-continuation-numbers* nil)
(defvar *copy-of-number-continuations* nil)

(defparameter *flow-current-x* 0)
(defparameter *flow-current-y* 0)

(defparameter *flow-current-scaling* 1)

(defparameter *flow-print-lines* 1)
(defparameter *flow-print-level* 2)
(defparameter *flow-print-length* 3)

(defvar *ir1-flow* (make-hash-table))

;;; Utilities
(defmacro center-of (&rest n)
  (when n `(the real (/ (+ ,@n) ,(length n)))))

(defmacro ensure-list (thing)
  `(or (and (listp ,thing) ,thing) (list ,thing)))

(defmacro print-log (&rest args)
  `(format *terminal-io* "~&~a~%" (format nil ,@args)))

(defmacro define-alias (alias name)
  (if (macro-function name)
      (progn
	(setf (macro-function alias) (macro-function name))
	`(load-time-value (setf (macro-function ',alias) (macro-function ',name))))
      (progn
	(setf (symbol-function alias) (symbol-function name))
	`(load-time-value (setf (symbol-function ',alias) (symbol-function ',name))))))

(define-alias min-x bounding-rectangle-min-x)
(define-alias max-x bounding-rectangle-max-x)
(define-alias min-y bounding-rectangle-min-y)
(define-alias max-y bounding-rectangle-max-y)

(defun map-over-polyline (func polyline)
  (declare (type (function (real real real real) *) func)
	   (type polyline polyline))
  (let ((line 1))
    (map-over-polygon-segments
     (lambda (&rest xy)
       (when (oddp line)
	 (apply func xy))
       (incf line))
     polyline))
  nil)

(defun line-middle-point (line)
  (multiple-value-bind (sx sy) (line-start-point* line)
    (multiple-value-bind (ex ey) (line-end-point* line)
      (make-point (center-of sx ex) (center-of sy ey)))))

(defun draw-text-in-bounding-rectangle* (stream text bound location &rest args)
  (let* ((old-size (getf args :text-size 256))
	 (record (with-output-to-output-record (stream)
                   (apply #'draw-text* stream text
                          (case location
                            ((:bottomleft :topleft) (1+ (min-x bound)))
                            ((:bottomright :topright) (1- (max-x bound)))
                            (t (center-of (min-x bound) (max-x bound))))
                          (case location
                            ((:topright :topleft) (1+ (min-y bound)))
                            ((:bottomright :bottomleft) (1- (max-y bound)))
                            (t (center-of (min-y bound) (max-y bound)))) args)))
	 (rec-bound (bounding-rectangle record))
	 (rec-bound-width (bounding-rectangle-width rec-bound)) 
	 (text-x (case location
		   ((:bottomleft :topleft) (1+ (min-x bound)))
		   ((:bottomright :topright) (1- (max-x bound)))
		   (t (center-of (min-x bound) (max-x bound)))))
	 (text-y (case location
		   ((:topright :topleft) (1+ (min-y bound)))
		   ((:bottomright :bottomleft) (1- (max-y bound)))
		   (t (center-of (min-y bound) (max-y bound))))))
    (when (or (< rec-bound-width (* *flow-current-scaling* (bounding-rectangle-width bound)))
	      (< old-size 4))
      (apply #'draw-text* stream text text-x text-y args)
      (return-from draw-text-in-bounding-rectangle* nil))
    (setf (getf args :text-size) (ceiling (- old-size 1)))
    (apply #'draw-text-in-bounding-rectangle* stream text bound location args)))

(defun find-path (start end step obstacles bound)
  (labels ((dist (p)
	     (sqrt (+ (* (- (point-x end) (point-x p))
			 (- (point-x end) (point-x p)))
	    	      (* (- (point-y end) (point-y p))
			 (- (point-y end) (point-y p))))))
	   (dist< (p1 p2)
	     (< (dist p1) (dist p2)))
	   (valid-walk-p (p1 p2 obs)
	     (let ((p12 (make-line p1 p2)))
	       (and (region-contains-region-p bound p12)
		    (every (lambda (o)
			     (or (eq o p1)
				 (and (not (region-contains-region-p o p2))
				      (not (region-intersects-region-p o p12)))))
			   obs))))
	   (coline-p (&rest args)
	     (or (every (lambda (p1 p2)
			  (= (point-x p1) (point-x p2)))
			args (rest args))
		 (every (lambda (p1 p2)
			  (= (point-y p1) (point-y p2)))
			args (rest args))))
	   (walk (p1 path)
	     (stable-sort
	      (remove-if-not
	       (lambda (p2)
		 (valid-walk-p p1 p2 (append path obstacles)))
	       (mapcar #'make-point
		       (list (point-x p1)           (point-x p1)          (+ (point-x p1) step) (- (point-x p1) step))
		       (list (+ (point-y p1) step) (- (point-y p1) step) (point-y p1)          (point-y p1))))
	      #'dist<))
	   (smooth-until-done (path)
	     (let ((smoothed nil))
	       (flet ((join (path)
			(do* ((p1 path)
			      (p2 (cdr p1) (cdr p1))
			      (p3 (cddr p1) (cddr p1)))
			     ((null p3) path)
			  (if (coline-p (first p1) (first p2) (first p3))
			      (progn
				(rplacd p1 p3)
				(setf smoothed nil))
			      (setf p1 (cdr p1)))))
		      (smoothy (path)
			(setf smoothed t)
			(do* ((p1 (cdr path) (cdr p1))
			      (p2 (cdr p1) (cdr p1))
			      (p3 (cddr p1) (cddr p1)))
			     ((or (null p3) (region-contains-region-p (first p3) start)) path)
			  (cond ((coline-p (first p1) (first p2) (first p3)) nil)
				(t (let* ((p4 (make-point (point-x (first p1)) (point-y (first p3))))
					  (p5 (make-point (point-x (first p3)) (point-y (first p1))))
					  (obs (append path obstacles)))
				     (cond ((and (valid-walk-p (first p1) p4 obs)
						 (valid-walk-p (first p3) p4 obs))
					    (rplaca p2 p4)
					    (rplacd p2 (cdr p3))
					    (setf smoothed nil))
					   ((and (valid-walk-p (first p1) p5 obs)
						 (valid-walk-p (first p3) p5 obs))
					    (rplaca p2 p5)
					    (rplacd p2 (cdr p3))
					    (setf smoothed nil)))))))))
		 (do () (smoothed path)
		   (setf path (join (smoothy path)))))))
	   (find-1 (p path)
	     (setf path (cons p path))
	     (when (<= (dist p) step)
	       (return-from find-path
		 (smooth-until-done
		  (if (region-contains-region-p end (first path))
		      path
		      (cons end path)))))
	     (mapcar (lambda (sp)
		       (find-1 sp path))
		     (walk p path))))
    (find-1 start nil)))

(defun draw-connector (stream text start-point end-point limit-bound &rest args &key (bounds (list +nowhere+)) (step 1) &allow-other-keys)
  (declare (ignorable text))
  (awhen (reverse (find-path start-point end-point step bounds limit-bound))
    (remf args :bounds)
    (remf args :step)
    (map nil
	 (lambda (p1 p2)
	   (apply #'draw-arrow stream p1 p2 args))
	 it (rest it))))

(defgeneric region-clear (pane region)
  (:method ((pane t) region) (declare (ignore pane region)) nil) 
  (:method ((pane clim-stream-pane) (region output-record))
    (let ((bound (bounding-rectangle region))
	  (top (stream-output-history pane)))
      (medium-clear-area (sheet-medium pane)
			 (bounding-rectangle-min-x bound)
			 (bounding-rectangle-min-y bound)
			 (bounding-rectangle-max-x bound)
			 (bounding-rectangle-max-y bound))
      (map-over-output-records-overlapping-region
       (lambda (record)
	 (unless (eq region record)
	   (replay-output-record record pane)))
       top region))))

(defmacro size-of ((stream) &body body)
  `(let ((record (with-output-to-output-record (,stream)
		   ,@body)))
     (bounding-rectangle-size record)))

(defun component-clambdas (component)
  (remove-duplicates
   (append (sb-c::component-new-functionals component)
	   (sb-c::component-lambdas component)
	   (sb-c::component-reanalyze-functionals component))))

;;; IR1 Regions
(defvar *recompute-p* nil)
(defvar *ir1-flow* nil)

(defun make-ir1-flow (clambda)
  (let ((component (sb-c::lambda-component clambda))
	(*flow-current-x* *flow-current-x*)
	(*flow-current-y* *flow-current-y*)
	(*ir1-flow* (make-hash-table)))
    (region-ir1 component)
    (cons component *ir1-flow*)))

(defun valid-region-p (region)
  (and region (not (eq region +nowhere+)) region))

(defmacro with-valid-region (region &body body)
  `(awhen (valid-region-p ,region)
     ,@body))

(defun margined-region (region &key (x-ratio *flow-margin-ratio-x*) (y-ratio *flow-margin-ratio-y*))
  (if (valid-region-p region)
      (make-bounding-rectangle (- (min-x region) (* x-ratio *flow-x-spacing*))
			       (- (min-y region) (* y-ratio *flow-y-spacing*))
			       (+ (max-x region) (* x-ratio *flow-x-spacing*))
			       (+ (max-y region) (* y-ratio *flow-y-spacing*)))
      region))

(defmacro define-ir1-region ((ir1 &key (recursively-recompute-p t)) &body body)
  `(defun ,(symbolicate 'region- ir1) (,ir1 &key (recompute-p *recompute-p*) (ir1-flow *ir1-flow*))
     (if ,ir1
	 (or (and (not recompute-p) (gethash ,ir1 ir1-flow nil))
	     (setf (gethash ,ir1 ir1-flow)
		   (let ((*recompute-p* (and ,recursively-recompute-p
					     (eq recompute-p :recursive)
					     :recursive))
			 (*ir1-flow* ir1-flow))
		     ,@body)))
	 +nowhere+)))

(define-ir1-region (ir1)
  (typecase ir1
    (sb-c::functional (region-functional ir1))
    (sb-c::component (region-component ir1))
    (sb-c::cblock (region-cblock ir1))
    (sb-c::ctran (region-ctran ir1))
    (sb-c::lvar (region-lvar ir1))
    (sb-c::node (region-node ir1))
    (t +nowhere+)))

(define-ir1-region (component)
  (let ((flow-original-x *flow-current-x*)
	(computed-blocks nil))
    (labels ((region-maybe-dangling-next-cblocks (cblock-head region)
	       (awhen (sb-c::block-next cblock-head)
		 (unless (sb-c::block-pred it)
		   (with-valid-region (region-union (region-cblock it) (region-cblocks it region))
		     (setf *flow-current-x* (+ flow-original-x
					       (bounding-rectangle-width it)
					       *flow-block-x-spacing*))
		     (return-from region-maybe-dangling-next-cblocks it))))
	       region)
	     (region-cblocks (cblock-head region)
	       (when (member cblock-head computed-blocks)
		 (return-from region-cblocks region))
	       (pushnew cblock-head computed-blocks)
	       (let ((*flow-current-x* *flow-current-x*))
		 (do* ((cblocks (next-of cblock-head) (rest cblocks))
		       (cblock (first cblocks) (first cblocks)))
		      ((null cblocks) (values region *flow-current-x* *flow-current-y*))
		   (let* ((*flow-current-y* *flow-current-y*)
			  (cblock-region (region-union region (region-cblock cblock)))
			  (cblock-with-dangling-region (region-maybe-dangling-next-cblocks cblock cblock-region))
			  (cblocks-region (region-cblocks cblock cblock-with-dangling-region)))
		     (with-valid-region cblocks-region
		       (setf region it
			     *flow-current-x* (+ flow-original-x
						 (bounding-rectangle-width it)
						 *flow-block-x-spacing*)))))))
	     (region-lvars (cblock-head)
	       (map-over-cblocks
		(lambda (cblock)
		  (do* ((ctran (sb-c::block-start cblock) (next-of node))
			(node (next-of ctran) (next-of ctran))
			(lvar (and (sb-c::valued-node-p node) (sb-c::node-lvar node)) (and (sb-c::valued-node-p node) (sb-c::node-lvar node))))
		       ((null ctran))
		    (region-lvar lvar)))
		ir1-flow))
	     (region-functionals ()
	       (multiple-value-bind (br cx cy) (region-cblocks (sb-c::component-head component) +nowhere+)
		 (declare (ignore br))
		 (let ((*flow-current-x* cx)
		       (*flow-current-y* cy))
		   (reduce #'region-union
			   (mapcar #'region-functional
				   (component-clambdas component))
			   :initial-value +nowhere+)))))
      (prog1 (margined-region (region-functionals))
	(region-lvars (sb-c::component-head component))))))

(define-ir1-region (functional)
  (typecase functional
    (sb-c::clambda (do* ((cblock (sb-c::lambda-block functional) (sb-c::block-next cblock))
			 (region (region-cblock cblock) (region-union region (region-cblock cblock))))
			((eq cblock (sb-c::node-block (sb-c::lambda-return functional)))
			 (margined-region (region-union region 
							(reduce #'region-union (mapcar #'region-functional (sb-c::lambda-children functional)) :initial-value +nowhere+))
					  :x-ratio *flow-clambda-margin-ratio-x*
					  :y-ratio *flow-clambda-margin-ratio-y*))))
    (sb-c::optional-dispatch
     (margined-region
      (reduce #'region-union
	      (remove-duplicates
	       (mapcar #'region-functional
		       (list*
			(sb-c::optional-dispatch-main-entry functional)
			(sb-c::optional-dispatch-more-entry functional)
			(mapcar #'sb-c::force (sb-c::optional-dispatch-entry-points functional)))))
	      :initial-value +nowhere+)
      :x-ratio *flow-clambda-margin-ratio-x*
      :y-ratio *flow-clambda-margin-ratio-y*))))

(define-ir1-region (cblock)
  (do* ((region +nowhere+ (region-union region (region-union (region-node node) (bounding-rectangle (region-ctran ctran)))))
	(ctran (sb-c::block-start cblock) (next-of node))
	(node (next-of ctran) (next-of ctran)))
       ((null ctran) (margined-region region :x-ratio *flow-block-margin-ratio-x* :y-ratio *flow-block-margin-ratio-y*))))

(define-ir1-region (ctran :recursively-recompute-p nil)
  (let ((use (unless (eq (sb-c::ctran-kind ctran) :block-start)
	       (region-node (previous-of ctran))))
	(dest (region-node (next-of ctran))))
    (if use
	(make-line* (center-of (max-x use) (min-x use))
		    (max-y use)
		    (center-of (max-x dest) (min-x dest))
		    (min-y dest))
	(make-line* (center-of (max-x dest) (min-x dest))
		    (- (min-y dest) *flow-y-spacing*)
		    (center-of (max-x dest) (min-x dest))
		    (min-y dest)))))

(define-ir1-region (lvar :recursively-recompute-p nil)
  (let ((uses (mapcar (lambda (node) (region-node node)) (previous-of lvar)))
	(dest (region-node (next-of lvar))))
    (make-polyline*
     (loop for use in uses
	append (cond ((<= (min-x dest) (min-x use) (max-x dest))
		      (list (min-x use)
			    (center-of (min-y use) (max-y use))
			    (min-x dest)
			    (center-of (min-y dest) (max-y dest))))
		     ((> (min-x use) (max-x dest))
		      (list (min-x use)
			    (center-of (min-y use) (max-y use))
			    (max-x dest)
			    (center-of (min-y dest) (max-y dest))))
		     ((<= (min-x dest) (max-x use) (max-x dest))
		      (list (max-x use)
			    (center-of (min-y use) (max-y use))
			    (max-x dest)
			    (center-of (min-y dest) (max-y dest))))
		     ((< (max-x use) (min-x dest))
		      (list (max-x use)
			    (center-of (min-y use) (max-y use))
			    (min-x dest)
			    (center-of (min-y dest) (max-y dest))))))
     :closed nil)))

(define-ir1-region (node :recursively-recompute-p nil)
  (setf *flow-current-y* (+ *flow-current-y* *flow-unit*))
  (prog1 (make-bounding-rectangle (- *flow-current-x* (/ *flow-unit* 2))
				  *flow-current-y*
				  (+ *flow-current-x* (/ *flow-unit* 2))
				  (+ *flow-current-y* *flow-unit*))
    (setf *flow-current-y* (+ *flow-current-y* *flow-y-spacing*))
    (when (eq node (sb-c::block-last (sb-c::node-block node)))
      (setf *flow-current-y* (+ *flow-current-y* *flow-block-y-spacing*)))))

(defun previous-of (ir1)
  (typecase ir1
    (sb-c::ctran (and (not (eq (sb-c::ctran-kind ir1) :block-start))
                      (sb-c::ctran-use ir1)))
    (sb-c::node (sb-c::node-prev ir1))
    (sb-c::lvar (ensure-list (sb-c::lvar-uses ir1)))
    (sb-c::cblock (sb-c::block-pred ir1))
    (t nil)))

(defun next-of (ir1)
  (typecase ir1
    (sb-c::ctran (sb-c::ctran-next ir1))
    (sb-c::node (sb-c::node-next ir1))
    (sb-c::lvar (sb-c::lvar-dest ir1))
    (sb-c::cblock (sb-c::block-succ ir1))
    (t nil)))

(defun list-all-cblocks-regions (ir1-flow &key except)
  (loop for ir1 being each hash-key in ir1-flow
     when (and (sb-c::block-p ir1) (not (member ir1 except))) 
     collect (region-ir1 ir1 :recompute-p nil :ir1-flow ir1-flow)))

(defun map-over-cblocks (func ir1-flow)
  (loop for ir1 being each hash-key in ir1-flow
     when (sb-c::block-p ir1) 
     do (funcall func ir1))
  nil)

;;; Clim
(defclass flow-pane (application-pane) ())
(defclass info-pane (application-pane) ())

(define-application-frame ir1-viewer ()
  ((ir1-flow :reader ir1-flow :initarg :ir1-flow)
   (ir1-node-flow-presentations :reader ir1-node-flow-presentations :initform (make-hash-table)))
  (:pointer-documentation t)
  (:panes
   ;; clim kludge: having the pane specifier name be the same
   ;; as in the macro confuses find-pane-named
   (flow-graph (make-clim-stream-pane :type 'flow-pane
                                      :name 'flow
                                      :display-function #'draw-flow-pane
                                      :display-time nil
                                      :end-of-page-action :allow
                                      :scroll-bars :both
                                      :default-view +flow-view+))
   (annotation (make-clim-stream-pane :type 'info-pane
                                      :name 'info
                                      :display-time nil
                                      :scroll-bars :both
                                      :default-view +textual-view+)))
  (:layouts
   (default
    (horizontally ()
      (2/3 flow-graph)
      (1/3 annotation)))
   (only-flow
    flow-graph)))

(defun run-viewer (clambda)
  (let ((ir1-flow (make-ir1-flow clambda)))
    (bt:make-thread (lambda ()
                      (run-frame-top-level
                       (make-application-frame 'ir1-viewer
                                               :ir1-flow ir1-flow
                                               :create t
                                               :frame-class 'ir1-viewer))))))

(defun draw-flow-pane (frame stream)
  (draw-flow (ir1-flow frame)
             (ir1-node-flow-presentations frame)
             stream))

(defun draw-flow (ir1-flow presentation-map stream &key (view +flow-view+))
  (window-clear stream)
  (let ((component-region (region-component (car ir1-flow))))
    (with-scaling (stream *flow-current-scaling*)
      (with-translation (stream (- (min-x component-region)) (- (min-y component-region)))
	(with-drawing-options (stream)
	  (loop for ir1 being each hash-key in (rest ir1-flow)
	     do (progn
		  (draw-ir1-extra ir1 stream ir1-flow)
                  (setf (gethash ir1 presentation-map)
                        ;; used for side-effect
                        (present ir1 (presentation-type-of ir1) :stream stream :view view)))))))))

(define-ir1-viewer-command com-describe ((ir1 'ir1))
  (when (eq (frame-current-layout *application-frame*) 'default)
    (let ((stream (find-pane-named *application-frame* 'info)))
      (window-clear stream)
      (handler-case (describe ir1 stream)
	(error (e) (notify-user *application-frame* (format nil "~a" e)))))))

(define-ir1-viewer-command (com-zoom-in :menu t :keystroke (:z :shift)) ()
  (setf *flow-current-scaling* (* 2 *flow-current-scaling*))
  (redisplay-frame-pane *application-frame* 'flow :force-p t))

(define-ir1-viewer-command (com-zoom-out :menu t :keystroke :z) ()
  (setf *flow-current-scaling* (/ *flow-current-scaling* 2))
  (redisplay-frame-pane *application-frame* 'flow :force-p t))

(define-ir1-viewer-command (com-toggle-info :menu t :keystroke :f) ()
  (if (eq (frame-current-layout *application-frame*) 'default)
      (setf (frame-current-layout *application-frame*) 'only-flow)
      (setf (frame-current-layout *application-frame*) 'default)))

(define-ir1-viewer-command (com-quit :menu t :keystroke :q) ()
  (frame-exit *application-frame*))

;;; IR1 Presentation
(labels ((present-instance-slots-clim (thing stream)
           (let ((slots (closer-mop:class-slots (class-of thing))))
             (formatting-table (stream)
               (dolist (slot slots)
                 (formatting-row (stream)
                   (formatting-cell (stream)
                     (present (closer-mop:slot-definition-name slot)
			      'symbol
			      :stream stream))
                   (formatting-cell (stream)
                     (if (slot-boundp thing (closer-mop:slot-definition-name slot))
                         (let ((val (slot-value thing (closer-mop:slot-definition-name slot))))
			   (present val (presentation-type-of val) :stream stream))
                         (format stream "<unbound>"))))))))
         
         (describe-instance (thing a-what stream)  
           (clim:present thing (clim:presentation-type-of thing)
                         :stream stream)
           (format stream " is ~A of type " a-what)
           (clim:present (type-of thing) (clim:presentation-type-of (type-of thing))
                         :stream stream)
           (terpri stream)
	   (terpri stream)
           (format stream "It has the following slots:~%")
	   (present-instance-slots-clim thing stream)))
  
  (defmethod describe-object ((thing standard-object) (stream application-pane))
    (describe-instance thing "an instance" stream))
  
  (defmethod describe-object ((thing structure-object) (stream application-pane))
    (describe-instance thing "a structure" stream)))

(defstruct (ir1 (:constructor make-ir1 ()))
  (|bogus-can't-be-instantiated|
   (error "ir1 is not a concrete ir1 thing.")))

(defmacro define-ir1-presentation-type ((&rest types) &rest args)
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     ,@(when types
	     `((define-presentation-type ,(car types) ,@args)
	       (define-ir1-presentation-type ,(cdr types) ,@args)))
     nil))

(define-ir1-presentation-type (ir1) ())

(define-ir1-presentation-type (sb-c::cblock
			       sb-c::functional
			       sb-c::component
			       sb-c::ctran
			       sb-c::lvar
			       sb-c::node
			       sb-c::lexenv) () :inherit-from 'ir1)

(define-ir1-presentation-type (sb-c::bind
			       sb-c::cast
			       sb-c::cif
			       sb-c::creturn
			       sb-c::entry
			       sb-c::exit
			       sb-c::ref
			       sb-c::basic-combination) () :inherit-from 'sb-c::node)

(define-ir1-presentation-type (sb-c::combination
			       sb-c::mv-combination) () :inherit-from 'sb-c::basic-combination)

(define-ir1-presentation-type (sb-c::clambda
			       sb-c::optional-dispatch) () :inherit-from 'sb-c::functional)

(define-presentation-to-command-translator describe (ir1 com-describe ir1-viewer :gesture :select) (object)
  (list object))

(macrolet ((def (ir1)
	     `(defmethod print-object :around ((ctran ,ir1) stream)
		(let nil
                  #+(or)
                    ((sb-c::*continuation-numbers* *copy-of-continuation-numbers*)
                     ( sb-c::*number-continuations* *copy-of-number-continuations*))
                  (call-next-method)))))
  (def sb-c::ctran)
  (def sb-c::lvar)
  (def sb-c::cblock))

(define-presentation-method present (ir1 (type ir1) stream view &key)
  (print ir1 stream))

(defmacro define-ir1-presentation (((&rest types) stream) &body body)
  (when (and types
             (/= 0 (or (position :as types) -1)))
    (let* ((as-nm (second (member :as types)))
           (type-nm (first types))
           (draw-fn (symbolicate 'draw- type-nm))
           (sb-type (intern (symbol-name type-nm) :sb-c)))
      `(progn
         (defun ,draw-fn (,(or as-nm type-nm) ,stream) ,@body)
         (define-presentation-method present (,type-nm (type ,sb-type) stream (view flow-view) &key)
           (,draw-fn ,type-nm stream))
         (define-presentation-method highlight-presentation
             ((type ,sb-type) record (stream flow-pane) state)
           (let* ((component-region (region-component (car (ir1-flow *application-frame*))))
                  (ir1 (presentation-object record))
                  (reg (bounding-rectangle record)))
             (ecase state
               (:highlight
                (region-clear stream record)
                (with-scaling (stream *flow-current-scaling*)
                  (with-translation (stream (- (min-x component-region)) (- (min-y component-region)))
                    (with-drawing-options (stream :line-thickness 2 :ink +red+ :text-face :bold)
                      (,draw-fn ir1 stream)))))
               (:unhighlight
                (repaint-sheet stream
                               (make-bounding-rectangle (1- (min-x reg))
                                                        (1- (min-y reg))
                                                        (max-x reg)
                                                        (max-y reg)))))))
         (define-presentation-method highlight-presentation
             ((type ,sb-type) record (stream info-pane) state)
           (let ((frame *application-frame*))
             (clim-internals::highlight-presentation-1
              (gethash (presentation-object record)
                       (ir1-node-flow-presentations frame))
              (find-pane-named frame 'flow)
              state))
           (call-next-method))
         (define-ir1-presentation (,(cdr types) stream) ,@body)))))

(define-ir1-presentation ((node) stream)
  (with-valid-region (region-node node)
    (let* ((rb (region-cblock (sb-c::node-block node)))
	   (nb (make-bounding-rectangle (min-x rb) (min-y it) (max-x rb) (max-y it))))
      (draw-text-in-bounding-rectangle* stream (label-ir1 node) nb :center :align-x :center :align-y :center))
    (draw-circle* stream
		  (center-of (min-x it) (max-x it))
		  (center-of (min-y it) (max-y it))
		  (center-of (max-y it) (- (min-y it)))
		  :filled nil)))

(define-ir1-presentation ((ctran) stream)
  (with-valid-region (region-ctran ctran)
    (draw-arrow stream
		(line-start-point it)
		(line-end-point it)
		:ink +red+)
    (draw-text stream (label-ir1 ctran) (line-middle-point it) :align-x :left :align-y :center)))

(define-ir1-presentation ((lvar) stream)
  (let ((uses (previous-of lvar)))
    (with-valid-region (region-lvar lvar)
      (map-over-polyline
       (lambda (x1 y1 x2 y2)
	 (if (/= x1 x2)
	     (progn
	       (draw-arrow* stream x1 y1 x2 y2 :ink +green+)
	       (draw-text* stream (label-ir1 lvar) (center-of x1 x2) (center-of y1 y2) :align-x :left :align-y :center))
	     (let* ((component (sb-c::block-component (sb-c::node-block (first uses)))))
	       (with-valid-region (region-component component)
		 (let* ((component-height (- (max-y it) (min-y it)))
			(lvar-length (sqrt (+ (* (- x2 x1) (- x2 x1)) (* (- y2 y1) (- y2 y1)))))
			(lvar-shift (/ (* *flow-lvar-x-spacing-ratio* *flow-x-spacing* lvar-length) component-height)))
		   (draw-line* stream
			       x1 y1
			       (- x1 lvar-shift) (if (> y1 y2) (- y1 lvar-shift) (+ y1 lvar-shift))
			       :ink +green+)
		   (draw-line* stream
			       (- x1 lvar-shift) (if (> y1 y2) (- y1 lvar-shift) (+ y1 lvar-shift))
			       (- x2 lvar-shift) (if (> y1 y2) (+ y2 lvar-shift) (- y2 lvar-shift))
			       :ink +green+)
		   (draw-text* stream (label-ir1 lvar)
			       (center-of (- x1 lvar-shift) (- x2 lvar-shift))
			       (center-of (if (> y1 y2) (- y1 lvar-shift) (+ y1 lvar-shift)) (if (> y1 y2) (+ y2 lvar-shift) (- y2 lvar-shift)))
			       :align-x :right :align-y :center)
		   (draw-arrow* stream
				(- x2 lvar-shift) (if (> y1 y2) (+ y2 lvar-shift) (- y2 lvar-shift))
				x2 y2 
				:ink +green+))))))
       it))))

(define-ir1-presentation ((cblock component functional :as ir1) stream)
  (with-valid-region (region-ir1 ir1)
    (draw-text-in-bounding-rectangle* stream (label-ir1 ir1) it :topleft :align-x :left :align-y :top)
    (draw-rectangle* stream
		     (min-x it)
		     (min-y it)
		     (max-x it)
		     (max-y it)
		     :filled nil)))

;;; IR1 Extra Drawing
(defgeneric draw-ir1-extra (ir1 &optional stream ir1-flow)
  (:method ((ir1 t) &optional (stream *standard-output*) ir1-flow) (declare (ignore stream ir1-flow)) nil))

(defmethod draw-ir1-extra ((cblock sb-c::cblock) &optional (stream *standard-output*) ir1-flow)
  (with-valid-region (region-cblock cblock)
    (let ((pred-it it))
      (dolist (succ (next-of cblock))
	(with-valid-region (region-cblock succ)
	  (let ((cx1 (center-of (min-x pred-it) (max-x pred-it)))
		(cy1 (max-y pred-it))
		(cx2 (center-of (min-x it) (max-x it)))
		(cy2 (min-y it)))
	    (draw-connector stream "not implemented :("
			    (make-point cx1 cy1) (make-point cx2 cy2)
			    (region-component (sb-c::block-component cblock))
			    :ink +blue+
			    :line-dashes '(#b101)
			    :bounds (list-all-cblocks-regions (cdr ir1-flow))
			    :step (/ *flow-block-x-spacing* 4))))))))

(defmethod draw-ir1-extra ((component sb-c::component) &optional (stream *standard-output*) ir1-flow)
  (declare (ignore ir1-flow))
  (with-valid-region (region-component component)
    (let ((pred-it it))
      (dolist (succ (next-of (sb-c::component-head component)))
	(with-valid-region (region-cblock succ)
	  (draw-arrow* stream
		       (center-of (min-x pred-it) (max-x pred-it))
		       (min-y pred-it)
		       (center-of (min-x it) (max-x it))
		       (min-y it)
		       :ink +blue+
		       :line-dashes '(#b101)))))))

;;; IR1 Labels
(defgeneric label-ir1 (ir1)
  (:method ((ir1 t)) "")
  (:method :around ((ir1 t))
	   (let ((*print-lines* *flow-print-lines*)
		 (*print-level* *flow-print-level*)
		 (*print-length* *flow-print-length*))
	     (call-next-method))))

(defmethod label-ir1 ((ir1 sb-c::functional))
  (format nil "~a:~s {~x}" (type-of ir1) (or (sb-c::functional-%debug-name ir1) (sb-c::functional-%source-name ir1)) (sb-c::get-lisp-obj-address ir1)))

(defmethod label-ir1 ((ir1 sb-c::component))
  (format nil "~a:~s" (type-of ir1) (sb-c::component-name ir1)))

(defmethod label-ir1 ((ir1 sb-c::cblock))
  (format nil "~a" (type-of ir1)))

(defmethod label-ir1 ((ir1 sb-c::node))
  (handler-case
      (if (sb-c::ref-p ir1)
          (let ((leaf (sb-c::ref-leaf ir1)))
            (if (sb-c::functional-p leaf)
                (format nil "~a:~s {~x}"
                        (type-of ir1)
                        (or (sb-c::functional-%debug-name leaf) (sb-c::functional-%source-name leaf))
                        (sb-c::get-lisp-obj-address leaf))
                (if (sb-c::constant-p leaf)
                    (format nil "~a:~a"
                            (type-of ir1)
                            (let ((value (sb-c::constant-value leaf)))
                              (if (consp value)
                                  (format nil "(LIST ~{~s~^ ~s~})"
                                          (mapcar (lambda (val)
                                                    (if (sb-c::leaf-p val)
                                                        (sb-c::leaf-%source-name val)
                                                        val)) value))
                                  (format nil "~s"
                                          (if (sb-c::leaf-p value)
                                              (sb-c::leaf-%source-name value)
                                              value)))))
                    (format nil "~a:~s"
                            (type-of ir1)
                            (sb-c::leaf-%source-name leaf)))))
          (let ((form (sb-c::node-source-form ir1)))
            (format nil "~a:~s" (type-of ir1)
                    (if (sb-c::leaf-p form)
                        (or (sb-c::leaf-%debug-name form) (sb-c::leaf-%source-name form))
                        form))))
    (error () (format nil "~a" (type-of ir1)))))

;;; Top Interface

;;; Clim GUI
(define-condition view-ir1 (simple-condition)
  ((clambda :initarg :clambda :reader clambda)))

(defun coerce-to-lambda-form (functoid-form)
  (case (first functoid-form)
    ((defun sb-int:named-lambda) `(lambda () ,(cadddr functoid-form)))
    ((lambda) functoid-form)
    (eval-when `(lambda () ,@(cddr functoid-form)))
    (otherwise `(lambda () ,functoid-form))))

(defun capture-and-view-next-compile ()
  (unlock-package (find-package "SB-C"))
  (unlock-package (find-package "SB-IMPL"))
  (let ((%simple-eval (symbol-function 'sb-impl::%simple-eval))
        (make-functional-from-toplevel-lambda (symbol-function 'sb-c::make-functional-from-toplevel-lambda)))
    (setf (symbol-function 'sb-impl::%simple-eval)
          (lambda (expr lexenv)
            (setf (symbol-function 'sb-impl::%simple-eval)
                  %simple-eval)
            (handler-case (let ((*error-output* (make-string-output-stream)))
                            (funcall %simple-eval expr lexenv))
              (condition (condition)
                (print-log "returning~%")
                (values (compile nil (coerce-to-lambda-form expr))
                        (clambda condition)))))
          (symbol-function 'sb-c::make-functional-from-toplevel-lambda)
          (lambda (lambda-expression &key name
                                     (path (sb-c::missing-arg)))
            (setf (symbol-function 'sb-c::make-functional-from-toplevel-lambda)
                  make-functional-from-toplevel-lambda)
            (print-log "compiling ~a~%" lambda-expression)
            (let ((clambda (funcall make-functional-from-toplevel-lambda
                                    lambda-expression
                                    :name name
                                    :path path)))
              #+nil
              (setf *copy-of-continuation-numbers* sb-c::*continuation-numbers*
                    *copy-of-number-continuations* sb-c::*number-continuations*)
              (print-log "viewing ~a~%" clambda)
              (run-viewer clambda)
              (signal 'view-ir1 :clambda clambda)
              clambda)))))

(defmacro view (form)
  `(progn
     (capture-and-view-next-compile)
     ,(case (first form)
        ((defun sb-int:named-lambda lambda) form)
        (eval-when `(lambda () ,@(cddr form)))
        (otherwise `(lambda () ,form)))))

;;; Dump PS file
(defmethod window-clear (pane) nil)

(defmacro dump (body &key (to-dir "~/"))
  (with-unique-names (make-functional-from-toplevel-lambda fmake-functional-from-toplevel-lambda)
    `(progn
       (unlock-package (find-package :sb-c))
       (defparameter ,make-functional-from-toplevel-lambda (symbol-function 'sb-c::make-functional-from-toplevel-lambda))
       (defun ,fmake-functional-from-toplevel-lambda (lambda-expression &key name (path (sb-c::missing-arg)))
	 (setf (symbol-function 'sb-c::make-functional-from-toplevel-lambda) ,make-functional-from-toplevel-lambda)
	 (print-log "compiling ~a~%" lambda-expression)
	 (let* ((clambda (funcall ,make-functional-from-toplevel-lambda lambda-expression :name name :path path))
		(ps (merge-pathnames (pathname (format nil "~a-~a.ps" 
						       (sb-c::component-name (sb-c::lambda-component clambda))
						       (sb-kernel::get-lisp-obj-address (sb-c::lambda-component clambda))))
				     ,to-dir)))
	   (print-log "dumping ~a to ~a ~%" clambda ps)
	   (progn (with-open-file (f ps :direction :output :if-exists :supersede :if-does-not-exist :create)
		    (let ((*flow-print-level* nil)
			  (*flow-print-length* nil))
		      (with-output-to-postscript-stream (s f :device-type :eps)
			(draw-flow (make-ir1-flow clambda) s)))))
	   (setf (symbol-function 'sb-c::make-functional-from-toplevel-lambda) #',fmake-functional-from-toplevel-lambda)
	   (print-log "returning ~%")
	   clambda))
       ((lambda ()
	  (unwind-protect
	       (progn
		 (setf (symbol-function 'sb-c::make-functional-from-toplevel-lambda) #',fmake-functional-from-toplevel-lambda)
		 (eval ',body))
	    (setf (symbol-function 'sb-c::make-functional-from-toplevel-lambda) ,make-functional-from-toplevel-lambda)))))))
