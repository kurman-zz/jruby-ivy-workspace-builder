Intent
=====

----
My tool to make me productive at client site. 

Purpose
=======
Auto-generate eclipse workspace from wellformed but customized IVY files. It allows me choosing which projects/modules are binaries.

----

Implementation
==============
I used JRuby to call IVY API for resolving and retrieving dependencies and ERB templates to generate project files. The trick I used is to use "source link" option in eclipse to point to sources and generate workspace in separate place so that I do not clutter versioned code.

