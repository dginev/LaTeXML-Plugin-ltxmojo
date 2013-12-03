#======================================================================
# Makefile Maker for ltxMojo - LaTeXML's web service
# d.ginev@jacobs-university.de
#======================================================================
use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  NAME => 'LtxMojo',
  AUTHOR => 'Deyan Ginev <d.ginev@jacobs-university.de>',
  ABSTRACT => "ltxMojo - LaTeXML's web service",
  VERSION_FROM => 'lib/LtxMojo.pm',
  PREREQ_PM => {
    'LaTeXML' => '0.7.9',
    'Mojolicious' => '4.0',
    'Archive::Zip' => 0,
    'IO::String' => 0
  },
  EXE_FILES => ['script/ltxmojo'],
  test => {TESTS => 't/*.t'}
);
