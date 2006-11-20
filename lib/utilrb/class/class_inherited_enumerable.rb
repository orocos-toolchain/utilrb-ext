require 'utilrb/module/module_inherited_enumerable'

class Class
    # Defines an attribute as being enumerable in the class instance and in the
    # whole class inheritance hierarchy.  More specifically, it defines a
    # <tt>each_#{name}(&iterator)</tt> instance method and a <tt>each_#{name}(&iterator)</tt>
    # class method which iterates (in order) on 
    # - the instance #{name} attribute
    # - the singleton class #{name} attribute
    # - the class #{name} attribute
    # - the superclass #{name} attribute
    # - the superclass' superclass #{name} attribute
    # ...
    #
    # The +name+ option defines the enumeration method name (+value+ will
    # define a +each_value+ method). +attribute_name+ defines the attribute
    # name. +init+ is a block called to initialize the attribute. 
    # Valid options in +options+ are: 
    # map:: the attribute should respond to +[]+. The enumeration method takes two 
    #	    arguments, +key+ and +uniq+. If +key+ is given, we iterate on the values
    #	    given by <tt>attribute[key]</tt>. If +uniq+ is true, the enumeration will
    #	    yield at most one value for each +key+ found (so, if both +key+ and +uniq+ are
    #	    given, the enumeration yields at most one value)
    #
    # For instance
    #
    #	class A 
    #	    class_inherited_enumerable("value", "enum") { Array.new }
    #	end
    #	class B < A
    #	end
    #	b = B.new
    #
    #	A.enum << 1
    #	B.enum << 2
    #	class << b
    #	    enum << 3
    #	end
    #
    #	A.each_enum => 1
    #	B.each_enum => 2, 1
    #	b.singleton_class.each_enum => 3, 2, 1
    #
    def class_inherited_enumerable(name, attribute_name = name, options = Hash.new, &init)
	singleton_class.class_eval { module_inherited_enumerable(name, attribute_name, options, &init) }
    end
end



