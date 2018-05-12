# Cxx.jl - The Julia C++ FFI

Cxx.jl is a Julia package that provides a C++ interoperability
interface for Julia. It also provides an experimental C++ REPL
mode for the Julia REPL.

## Functionality

There are two ways to access the main functionality provided by
this package. The first is using the `@cxx` macro, which puns on
Julia syntax to provide C++ compatibility.
Additionally, this package provides the `cxx""` and `icxx""` custom
string literals for inputting C++ syntax directly. The two string
literals are distinguished by the C++ level scope they represent.
See the API documentation for more details.

## Installation

The package is installable on Julia 0.5 and newer and is available
through Julia's package manager:

```julia
Pkg.add("Cxx")
```

Building the C++ code requires the same
[system tools](https://github.com/JuliaLang/julia#required-build-tools-and-external-libraries)
necessary for building Julia from source.
Further, Debian/Ubuntu users should install `libedit-dev` and `libncurses5-dev`,
and RedHat/CentOS users should install `libedit-devel`.

## Contents

```@contents
Pages = [
    "api.md",
    "examples.md",
    "implementation.md",
    "repl.md",
]
Depth = 1
```
