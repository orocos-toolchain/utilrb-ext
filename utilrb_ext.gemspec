# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'utilrb/ext_version'

Gem::Specification.new do |s|
    s.name = "utilrb-ext"
    s.version = Utilrb::EXT_VERSION
    s.authors = ["Sylvain Joyeux"]
    s.email = "sylvain.joyeux@m4x.org"
    s.summary = "Functionality which depend on a C extension for Utilrb, yet another Ruby toolkit"
    s.description = "This package contains the Utilrb functionality that depend on a C extension"
    s.homepage = "http://rock-robotics.org"
    s.licenses = ["BSD"]

    s.require_paths = ["lib"]
    s.extensions = []
    s.extra_rdoc_files = []
    s.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }

    s.add_runtime_dependency "rake", ">= 0.9"
    s.add_runtime_dependency "rake-compiler", "~> 0.8.0"
    s.add_development_dependency "utilrb", ">= 2.0"
    s.add_development_dependency "flexmock", ">= 2.0.0"
    s.add_development_dependency "minitest", ">= 5.0", "~> 5.0"
    s.add_development_dependency "coveralls"
end
