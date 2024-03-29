;;;
;;; Tools to handle data conversion to PostgreSQL format
;;;
;;; Any function that you want to use to transform data with will get looked
;;; up in the pgloader.transforms package, when using the default USING
;;; syntax for transformations.

(in-package :pgloader.transforms)

;;;
;;; This package is used to generate symbols in the CL code that
;;; project-fields produces, allowing to use symbols such as t. It's
;;; important that the user-symbols package doesn't :use cl.
;;;
(defpackage #:pgloader.user-symbols (:use))

(defun intern-symbol (symbol-name &optional (overrides '()))
  "Return a symbol in either PGLOADER.TRANSFORMS if it exists there
   already (it's a user provided function) or a PGLOADER.USER-SYMBOLS
   package.

   OVERRIDES is an alist of symbol . value, allowing called to force certain
   values: the classic example is how to parse the \"nil\" symbol-name.
   Given OVERRIDES as '((nil . nil)) the returned symbol will be cl:nil
   rather than pgloader.user-symbols::nil."
  (let ((overriden (assoc symbol-name overrides :test #'string-equal)))
    (if overriden
        (cdr overriden)

        (multiple-value-bind (symbol status)
            (find-symbol (string-upcase symbol-name)
                         (find-package "PGLOADER.TRANSFORMS"))
          ;; pgloader.transforms package (:use :cl) so we might find variable
          ;; names in there that we want to actually intern in
          ;; pgloader.user-symbols so that users may use e.g. t as a column name...
          ;; so only use transform symbol when it denotes a function
          (cond
            ((and status (fboundp symbol)) symbol) ; a transform function

            (t
             (intern (string-upcase symbol-name)
                     (find-package "PGLOADER.USER-SYMBOLS"))))))))

;;;
;;; Handling typmod in the general case, don't apply to ENUM types
;;;
(defun parse-column-typemod (data-type column-type)
  "Given int(7), returns the number 7.

   Beware that some data-type are using a typmod looking definition for
   things that are not typmods at all: enum."
  (unless (or (string= "enum" data-type)
	      (string= "set" data-type))
    (let ((start-1 (position #\( column-type))	; just before start position
	  (end     (position #\) column-type)))	; just before end position
      (when (and start-1 (< (+ 1 start-1) end))
	(destructuring-bind (a &optional b)
	    (mapcar #'parse-integer
		    (sq:split-sequence #\, column-type
				       :start (+ 1 start-1) :end end))
	  (list a b))))))

(defun typemod-expr-matches-p (rule-typemod-expr typemod)
  "Check if an expression such as (< 10) matches given typemod."
  (funcall (compile nil (typemod-expr-to-function rule-typemod-expr)) typemod))

(defun typemod-expr-to-function (expr)
  "Transform given EXPR into a callable function object."
  `(lambda (typemod)
     (destructuring-bind (precision &optional (scale 0))
         typemod
       (declare (ignorable precision scale))
       ,expr)))


;;;
;;; Some optimisation stanza
;;;
(declaim (inline intern-symbol
		 zero-dates-to-null
		 date-with-no-separator
		 time-with-no-separator
		 tinyint-to-boolean
		 bits-to-boolean
		 int-to-ip
		 ip-range
		 convert-mysql-point
		 integer-to-string
                 float-to-string
                 empty-string-to-null
		 set-to-enum-array
		 right-trim
		 byte-vector-to-bytea
                 sqlite-timestamp-to-timestamp
                 sql-server-uniqueidentifier-to-uuid
                 sql-server-bit-to-boolean
                 varbinary-to-string
                 base64-decode
		 hex-to-dec))


;;;
;;; Transformation functions
;;;
(defun zero-dates-to-null (date-string)
  "MySQL accepts '0000-00-00' as a date, we want NIL (SQL NULL) instead."
  (cond
    ((null date-string) nil)
    ((string= date-string "") nil)
    ;; day is 00
    ((string= date-string "0000-00-00" :start1 8 :end1 10 :start2 8 ) nil)
    ;; month is 00
    ((string= date-string "0000-00-00" :start1 5 :end1 7 :start2 5 :end2 7) nil)
    ;; year is 0000
    ((string= date-string "0000-00-00" :start1 0 :end1 3 :start2 0 :end2 3) nil)
    (t date-string)))

(defun date-with-no-separator
    (date-string
     &optional (format '((:year     0  4)
			 (:month    4  6)
			 (:day      6  8)
			 (:hour     8 10)
			 (:minute  10 12)
			 (:seconds 12 14))))
  "Apply this function when input date in like '20041002152952'"
  ;; only process non-zero dates
  (declare (type (or null string) date-string))
  (let ((str-length      (length date-string))
        (expected-length (reduce #'max (mapcar #'third format))))
    (cond ((null date-string)                   nil)
          ((string= date-string "")             nil)
          ((not (= expected-length str-length)) nil)
          (t
           (destructuring-bind (&key year month day hour minute seconds
                                     &allow-other-keys)
               (loop
                  for (name start end) in format
                  append (list name (subseq date-string start end)))
             (if (or (string= year  "0000")
                     (string= month "00")
                     (string= day   "00"))
                 nil
                 (format nil "~a-~a-~a ~a:~a:~a"
                         year month day hour minute seconds)))))))

(defun time-with-no-separator
    (time-string
     &optional (format '((:hour     0 2)
			 (:minute   2 4)
			 (:seconds  4 6)
			 (:msecs    6 nil))))
  "Apply this function when input date in like '08231560'"
  (declare (type (or null string) time-string))
  (when time-string
    (destructuring-bind (&key hour minute seconds msecs
                              &allow-other-keys)
        (loop
           for (name start end) in format
           append (list name (subseq time-string start end)))
      (format nil "~a:~a:~a.~a" hour minute seconds msecs))))

(defun tinyint-to-boolean (integer-string)
  "When using MySQL, strange things will happen, like encoding booleans into
   tinyiny that are either 0 (false) or 1 (true). Of course PostgreSQL wants
   'f' and 't', respectively."
  (when integer-string
    (if (string= "0" integer-string) "f" "t")))

(defun bits-to-boolean (bit-vector)
  "When using MySQL, strange things will happen, like encoding booleans into
   bit(1). Of course PostgreSQL wants 'f' and 't'."
  (when (and bit-vector (= 1 (length bit-vector)))
    (let ((bit (aref bit-vector 0)))
      ;; we might have either a char or a number here, see issue #684.
      ;; current guess when writing the code is that it depends on MySQL
      ;; version, but this has not been checked.
      (etypecase bit
        (fixnum    (if (= 0 bit) "f" "t"))
        (character (if (= 0 (char-code bit)) "f" "t"))))))

(defun int-to-ip (int)
  "Transform an IP as integer into its dotted notation, optimised code from
   stassats."
  (declare (optimize speed)
           (type (unsigned-byte 32) int))
  (let ((table (load-time-value
                (let ((vec (make-array (+ 1 #xFFFF))))
                  (loop for i to #xFFFF
		     do (setf (aref vec i)
			      (coerce (format nil "~a.~a"
					      (ldb (byte 8 8) i)
					      (ldb (byte 8 0) i))
				      'simple-base-string)))
                  vec)
                t)))
    (declare (type (simple-array simple-base-string (*)) table))
    (concatenate 'simple-base-string
		 (aref table (ldb (byte 16 16) int))
		 "."
		 (aref table (ldb (byte 16 0) int)))))

(defun ip-range (start-integer-string end-integer-string)
  "Transform a couple of integers to an IP4R ip range notation."
  (declare (optimize speed)
	   (type (or null string) start-integer-string end-integer-string))
  (when (and start-integer-string end-integer-string)
    (let ((ip-start (int-to-ip (parse-integer start-integer-string)))
          (ip-end   (int-to-ip (parse-integer end-integer-string))))
      (concatenate 'simple-base-string ip-start "-" ip-end))))

(defun convert-mysql-point (mysql-point-as-string)
  "Transform the MYSQL-POINT-AS-STRING into a suitable representation for
   PostgreSQL.

  Input:   \"POINT(48.5513589 7.6926827)\" ; that's using st_astext(column)
  Output:  (48.5513589,7.6926827)"
  (when mysql-point-as-string
    (let* ((point (subseq mysql-point-as-string 5)))
      (setf (aref point (position #\Space point)) #\,)
      point)))

(defun convert-mysql-linestring (mysql-linestring-as-string)
  "Transform the MYSQL-POINT-AS-STRING into a suitable representation for
   PostgreSQL.

  Input:   \"LINESTRING(-87.87342467651445 45.79684462673078,-87.87170806274479 45.802110434248966)\" ; that's using st_astext(column)
  Output:  [(-87.87342467651445,45.79684462673078),(-87.87170806274479,45.802110434248966)]"
  (when mysql-linestring-as-string
    (let* ((data (subseq mysql-linestring-as-string
                         11
                         (- (length mysql-linestring-as-string) 1))))
      (with-output-to-string (s)
        (write-string "[" s)
        (loop :for first := t :then nil
           :for point :in (split-sequence:split-sequence #\, data)
           :for (x y) := (split-sequence:split-sequence #\Space point)
           :do (format s "~:[,~;~](~a,~a)" first x y))
        (write-string "]" s)))))

(defun integer-to-string (integer-string)
  "Transform INTEGER-STRING parameter into a proper string representation of
   it. In particular be careful of quoted-integers, thanks to SQLite default
   values."
  (declare (type (or null string fixnum) integer-string))
  (when integer-string
    (princ-to-string
     (typecase integer-string
       (integer integer-string)
       (string  (handler-case
                    (parse-integer integer-string :start 0)
                  (condition (c)
                    (declare (ignore c))
                    (parse-integer integer-string :start 1
                                   :end (- (length integer-string) 1)))))))))

(defun float-to-string (float)
  "Transform a Common Lisp float value into its string representation as
   accepted by PostgreSQL, that is 100.0 rather than 100.0d0."
  (declare (type (or null fixnum float string) float))
  (when float
    (typecase float
      (double-float (let ((*read-default-float-format* 'double-float))
                      (princ-to-string float)))
      (string       float)
      (t            (princ-to-string float)))))

(defun set-to-enum-array (set-string)
  "Transform a MySQL SET value into a PostgreSQL ENUM Array"
  (when set-string
    (format nil "{~a}" set-string)))

(defun empty-string-to-null (string)
  "MySQL ENUM sometimes return an empty string rather than a NULL."
  (when string
    (if (string= string "") nil string)))

(defun right-trim (string)
  "Remove whitespaces at end of STRING."
  (declare (type (or null simple-string) string))
  (when string
    (string-right-trim '(#\Space) string)))

(defun remove-null-characters (string)
  "Remove NULL-characters (0x00) from STRING"
  (when string
    (remove #\Nul string)))

(defun byte-vector-to-bytea (vector)
  "Transform a simple array of unsigned bytes to the PostgreSQL bytea
  representation as documented at
  http://www.postgresql.org/docs/9.3/interactive/datatype-binary.html

  Note that we choose here the bytea Hex Format."
  (declare (type (or null string (simple-array (unsigned-byte 8) (*))) vector))
  (etypecase vector
    (null nil)
    (string (if (string= "" vector)
                nil
                (error "byte-vector-to-bytea called on a string: ~s" vector)))
    (simple-array
     (let ((hex-digits "0123456789abcdef")
           (bytea (make-array (+ 2 (* 2 (length vector)))
                              :initial-element #\0
                              :element-type 'standard-char)))

       ;; The entire string is preceded by the sequence \x (to distinguish it
       ;; from the escape format).
       (setf (aref bytea 0) #\\)
       (setf (aref bytea 1) #\x)

       (loop for pos from 2 by 2
          for byte across vector
          do (let ((high (ldb (byte 4 4) byte))
                   (low  (ldb (byte 4 0) byte)))
               (setf (aref bytea pos)       (aref hex-digits high))
               (setf (aref bytea (+ pos 1)) (aref hex-digits low)))
          finally (return bytea))))))

(defun ensure-parse-integer (string-or-integer)
  "Return an integer value if string-or-integer is an integer or a string
   containing only an integer value, in all other cases return nil."
  (typecase string-or-integer
    (string (multiple-value-bind (integer position)
                (parse-integer string-or-integer :junk-allowed t)
              (when (= (length string-or-integer) position)
                integer)))
    (integer string-or-integer)))

(defun sqlite-timestamp-to-timestamp (date-string-or-integer)
  (declare (type (or null integer simple-string) date-string-or-integer))
  (when date-string-or-integer
    (cond ((and (typep date-string-or-integer 'integer)
                (= 0 date-string-or-integer))
           nil)

          ((typep date-string-or-integer 'integer)
           ;; a non-zero integer is a year
           (format nil "~a-01-01" date-string-or-integer))

          ((stringp date-string-or-integer)
           ;; default values are sent as strings
           (let ((maybe-integer (ensure-parse-integer date-string-or-integer)))
             (cond ((and maybe-integer (= 0 maybe-integer))
                    nil)

                   (maybe-integer
                    (format nil "~a-01-01" maybe-integer))

                   (t
                    date-string-or-integer)))))))

(defun sql-server-uniqueidentifier-to-uuid (id)
  (declare (type (or null (array (unsigned-byte 8) (16))) id))
  (when id
    (format nil "~a" (uuid:byte-array-to-uuid id))))

(defun unix-timestamp-to-timestamptz (unixtime-string)
  "Takes a unix timestamp (seconds since beginning of 1970) and converts it
  into a string of format \"YYYY-MM-DD hh:mm:ssZ\".

  Assumes that the unix timestamp is in UTC time."
  (when unixtime-string
    (let ((unixtime (ensure-parse-integer unixtime-string))
          ;; Universal time uses a different epoch than unix time
          (unix-universal-diff (load-time-value
                                 (encode-universal-time 0 0 0 1 1 1970 0))))
      (multiple-value-bind
        (second minute hour date month year)
        (decode-universal-time (+ unixtime unix-universal-diff) 0)
        (format nil
                "~d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0dZ"
                year month date hour minute second)))))

(defun sql-server-bit-to-boolean (bit-string-or-integer)
  "We might receive bits as '((0))'"
  (typecase bit-string-or-integer
    (integer (if (= 0 bit-string-or-integer) "f" "t"))
    (string
     (cond ((string= "0" bit-string-or-integer) "f")
           ((string= "1" bit-string-or-integer) "t")
           ((string= "((0))" bit-string-or-integer) "f")
           ((string= "((1))" bit-string-or-integer) "t")
           (t nil)))))

(defun varbinary-to-string (string)
  (let ((babel::*default-character-encoding*
         (or qmynd::*mysql-encoding*
             babel::*default-character-encoding*)))
    (etypecase string
      (null nil)
      (string string)
      (vector (babel:octets-to-string string)))))

(defun base64-decode (string)
  (etypecase string
    (null    nil)
    (string (base64:base64-string-to-string string))))

(defun hex-to-dec (hex-string)
  (etypecase hex-string
    (null    nil)
    (integer hex-string)
    (string (write-to-string (parse-integer hex-string :radix 16)))))
