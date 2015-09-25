#include <ruby.h>
#include <set>

static VALUE mUtilrb;

using namespace std;

static VALUE kernel_is_immediate(VALUE klass, VALUE object)
{ return IMMEDIATE_P(object) ? Qtrue : Qfalse; }

static VALUE kernel_crash(VALUE klass)
{
    *((int*)0) = 10;
    // Return something to shut gcc up
    return Qfalse;
}

extern "C" void Init_value_set();

extern "C" void Init_utilrb()
{
    mUtilrb = rb_define_module("Utilrb");
    rb_define_singleton_method(rb_mKernel, "crash!", RUBY_METHOD_FUNC(kernel_crash), 0);
    rb_define_singleton_method(rb_mKernel, "immediate?", RUBY_METHOD_FUNC(kernel_is_immediate), 1);
    Init_value_set();
}

