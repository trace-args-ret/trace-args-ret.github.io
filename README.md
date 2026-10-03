# trace-args-ret.github.io
Argument and return value tracing via compiler-supported instrumentation `-fsanitize-coverage=trace-args,trace-ret`

# What Signal Are We Missing?

Traditional coverage tells us where execution went.

```
Input A                           Input B
   │                                │
   ▼                                ▼
 foo(x = 10)                     foo(x = 4096)
   │                                │
   └────── same control flow ───────┘
```

Control-flow coverage can tell us: `"foo() was reached."`

But sometimes we also need: `"foo() was reached with a value that has not been observed there before."`

![image](img/fig-0001-smb2-create.png)

Proposed additional signal:
```
  Function frame start  → argument values
  Function return       → returned values
```
![image](img/fig-0002-edge-vs-dataflow.png)

# What This Is, and What It Is Not

Not full data-flow or taint tracking

We do not reconstruct how every value was produced.

```mermaid
flowchart LR
    A["Fuzzer input"] --> B["Transformation A"]
    B --> C["Transformation B"]
    C --> D["Function argument"]
```

We do not attempt to answer:

1. Which input byte produced this value?
2. Which assignments and transformations contributed to it?
3. What is the complete data-dependency graph?
4. How can we use kcov-dataflow for Linux kernel fuzzing?
  - e.g., intergrating with syzkaller
  - I've PoC with LLVM LibFuzzer toward ksmbd, it is very interesting.
    - [e7188199eff4](https://github.com/torvalds/linux/commit/e7188199eff4) ksmbd: fix use-after-free in __close_file_table_ids() (CVE-2026-74522 CVSS3.1 score: 8.8)
    - [7405d0ba2943](https://github.com/torvalds/linux/commit/7405d0ba2943) ksmbd: fix slab-out-of-bounds read in ksmbd_alloc_user() (CVE-2026-90174 CVSS3.1 score: 7.1)
    - [fe2c0cacbcff](https://github.com/torvalds/linux/commit/fe2c0cacbcff) smb: smbdirect: free completion queues with ib_free_cq() (CVE-2026-90173 CVSS3.1 score: 9.8)
    - [383a9480f5f4](https://github.com/torvalds/linux/commit/383a9480f5f4) smb: smbdirect: destroy QP before mem pools on accept failure (CVE-2026-90172 CVSS3.1 score: 7.5)
    - [76fa42c004eb](https://github.com/torvalds/linux/commit/76fa42c004eb) smb: smbdirect: avoid recursive listen.lock during cleanup (CVE-2026-90170)
    - [db82fbe4bb68](https://github.com/torvalds/linux/commit/db82fbe4bb68) smb: smbdirect: release pending child sockets outside the handler lock (CVE-2026-90171)
    - [e9b33376bd07](https://github.com/torvalds/linux/commit/e9b33376bd07) ksmbd: validate ipc response length before dereferencing its fields (CVE-2026-90170)
    - [b0148dc5625d](https://github.com/torvalds/linux/commit/b0148dc5625d) ksmbd: serialize oplock close with pending break ownership (CVE-2026-90167)

Function-boundary value observation

```mermaid
flowchart LR
    A["Caller"] -->|"argument values"| B["Function"]
    B -->|"return value"| C["Caller"]
```

We observe which values cross function boundaries. We do not track how those values were produced.

# End-to-End Prototype

The prototype connects compiler instrumentation to two runtime consumers.

![image](img/fig-0003-dataflow-record.png)

```mermaid
flowchart TD
    A["C / C++ / Rust source"] --> B["Clang / LLVM"]
    B --> C["SanitizerCoverage<br/>trace-args / trace-ret"]

    C --> D["__sanitizer_cov_trace_args()"]
    C --> E["__sanitizer_cov_trace_ret()"]

    D --> F["Linux KCOV-dataflow"]
    E --> F

    F --> G["Per-task ARG / RET / CMP records"]
    G --> H["Kernel fuzzer / analyzer"]

    D --> I["compiler-rt / libFuzzer"]
    E --> I
    I --> J["ValueProfileMap"]
```

![image](img/fig-0004-llvm-inst-kernel-runtime.png)

The same compiler-side observation can therefore be consumed by:
- Linux kernel fuzzing
- userspace fuzzing through libFuzzer
- a custom runtime with strong callback definitions

The LLVM series implements the instrumentation, exposes the Clang options, adds the compiler-rt/libFuzzer runtime, and finally documents the complete interface.

# Linux Side: KCOV-Dataflow

The kernel prototype introduces a separate KCOV-dataflow facility.

```mermaid
flowchart LR
    A["Instrumented task"] --> B["trace_args"]
    A --> C["trace_ret"]
    A --> D["trace_cmp"]

    B --> E["KCOV-dataflow"]
    C --> E
    D --> E

    E --> F["Per-task buffer"]
    F --> G["mmap()"]
    G --> H["Userspace"]
```

Functionality added by the kernel patches Separate KCOV-dataflow device and buffer

1. Per-task collection
2. ARG, RET, and CMP record types
3. Execution sequence numbers
4. Remote kworker and kthread collection
5. Independent coexistence with ordinary KCOV

Build integration is opt-in per object (`KCOV_DATAFLOW_file.o := y`) or per
directory (`KCOV_DATAFLOW := y`), with `CONFIG_KCOV_DATAFLOW_INSTRUMENT_ALL` as
a whole-kernel escape hatch. `CONFIG_KCOV_DATAFLOW_NO_INLINE` adds `-fno-inline`
to the explicit opt-ins only, and deliberately not to everything INSTRUMENT_ALL
covers -- that configuration does not build, and since inlined callees are
reported anyway the flag now only changes how records are attributed.

# Per-Task, Execution-Ordered Observations

The output is not just a collection of argument values.
```
seq 100   ARG   foo arg0 = A
seq 101   ARG   foo arg1 = B
seq 102   CMP   B vs 0
seq 103   ARG   bar arg0 = B
seq 104   RET   bar = C
seq 105   RET   foo = D
```

Conceptually:

```mermaid
flowchart LR
    A["ARG records"] --> D["Ordered per-task stream"]
    B["CMP records"] --> D
    C["RET records"] --> D
    D --> E["Fuzzer / analyzer"]
```

This gives a consumer more context than a global set of values:
- Which function observed the value?
- Was it an argument, comparison operand, or return value?
- In what execution order was it observed?

The record's word [1] is the call site that produced it, with the KASLR offset
removed. "Which function" therefore has two answers depending on how the
consumer resolves it: `addr2line -i` against vmlinux names the inlined callee
and the chain above it, while kallsyms names only the function whose object code
the inlined body was merged into. All three record kinds -- ARG, RET and CMP --
derive that word the same way now.

# Existing KCOV Remains Independent

The prototype does not replace ordinary KCOV.
```mermaid
flowchart TD
    T["Task"] --> K["KCOV"]
    T --> DF["KCOV-dataflow"]

    K --> KB["PC / CMP buffer"]
    DF --> DB["ARG / RET / CMP buffer"]

    KB --> U["Userspace"]
    DB --> U
```

Each facility has independent:
- device
- file descriptor
- buffer
- per-task state
- enable / disable lifecycle

Open kernel integration question

Should function-boundary value observation remain a separate KCOV facility, become a KCOV mode, or live in a more general tracing infrastructure?

# Structured Values Require Runtime Reads

Direct values do not require a memory access.

```
Compiler
   │
   │ val = 42
   ▼
Kernel callback
   │
   └── record 42 directly
```

Structured objects use a different representation.

```mermaid
flowchart LR
    A["val = existing object address"] --> C["Kernel callback"]
    B["offsets = field layout"] --> C
    C --> D["No-fault field reads"]
    D --> E["Field 0 value"]
    D --> F["Field 1 value"]
    D --> G["Field N value"]
```

Responsibility for this feature:

- Compiler: describe the available value or object layout
- Runtime: decide whether and how the object can be read safely

Knowing an object’s type and layout does not prove that its address is safely readable.

## One Level Deep, and No Types

The table describes a struct's members. It does not describe *their* members,
and it does not say what any of them is. Both follow from it being a flat array
of `{byte offset, byte size}` pairs. In a struct with one of everything:

```c
struct inner { int a; int b; };

struct outer {
	char c;			/* 1 byte  */
	int i;			/* 4 bytes */
	double d;		/* 8 bytes */
	struct inner nested;	/* 8 bytes, inline */
	struct inner *heap;	/* 8 bytes, pointer to a dynamic object */
	void *opaque;		/* 8 bytes, no layout */
	long l;			/* 8 bytes */
};				/* 48 bytes */

void take(struct outer *o);
struct inner *give(struct outer *o);
```

```llvm
@__sancov_offsets_ = private unnamed_addr constant [14 x i64]
                       [i64 0,  i64 1,     ; c
                        i64 4,  i64 4,     ; i
                        i64 8,  i64 8,     ; d
                        i64 16, i64 8,     ; nested
                        i64 24, i64 8,     ; heap
                        i64 32, i64 8,     ; opaque
                        i64 40, i64 8]     ; l

call void @__sanitizer_cov_trace_args(i32 0, i32 48, i64 %2,
                                      ptr @__sancov_offsets_, i32 7)
```

The member comments are editorial; nothing in the table names a field or says
what kind of thing it is. Fields 2 through 6 are all `{offset, 8}`: a `double`,
an inline eight-byte struct, a pointer to a heap object, an opaque pointer, and
a `long`. Five source types, one indistinguishable description. `c` and `i` are
the only members whose size tells a consumer anything, and only because 1 and 4
are rarer widths than 8.

Why one level: the member loop never calls back into itself, so a member whose
type is a composite contributes one pair describing the whole of it. And a
pointer is followed in exactly one place, at the top:

```cpp
static DICompositeType *getTracedStructType(DIType *Ty) {
  Ty = stripTypedefsAndQualifiers(Ty);
  if (auto *Derived = dyn_cast_or_null<DIDerivedType>(Ty))
    if (Derived->getTag() == dwarf::DW_TAG_pointer_type)
      Ty = stripTypedefsAndQualifiers(Derived->getBaseType());
  ...
```

One `if`, not a loop. `struct outer *` is described; `struct outer **` is not,
and `outer.heap` is never asked about. The irony is that the answer is already
in the module: because `give()` returns `struct inner *`, the same translation
unit emits `struct inner`'s layout a few bytes away in `.rodata`, and nothing
links `outer`'s fifth field to it.

```llvm
@__sancov_offsets_.1 = private unnamed_addr constant [4 x i64]
                         [i64 0, i64 4, i64 4, i64 4]   ; struct inner

call void @__sanitizer_cov_trace_ret(i32 8, i64 %5,
                                     ptr @__sancov_offsets_.1, i32 2)
```

The flat table is the compiler's view. A consumer sees less, because the kernel
reads the table itself and the table does not travel:

```c
/* kernel/kcov_dataflow.c:525 */
			if (sz > sizeof(fval))
				sz = sizeof(fval);
			if (copy_from_kernel_nofault(&fval, fa, sz))
				fval = KCOV_DF_MAGIC_BAD;
			area[start_index + 3 + i] = fval;
```

A record is header, pc, object address, then `nvals` value words. The offsets
and sizes stay in kernel `.rodata`, so even the `{0, 1}`-versus-`{4, 4}`
distinction the compiler *did* record never reaches user space -- which is why
`trigger-view.py` can only print `{f0, f1, ...}`.

Two losses with nothing to flag them:

- An inline member wider than eight bytes is truncated to its first eight. The
  compiler records the true width -- `struct holder { int tag; struct wide w; }`,
  where `struct wide` is two `long`s, yields `[i64 0, i64 4, i64 8, i64 16]` --
  and the clamp above keeps only `w.a`.

- `KCOV_DF_HDR_SIZE_MASK` is `0xFF`, so an object larger than 255 bytes reports
  a clamped `size` in its header.

Neither sets a flag, and neither is distinguishable from a correct record.

What a consumer can do today:

- An inline member of eight bytes or fewer: the data is there, packed into one
  `u64`. Unpack it by hand, knowing the type from outside the record. Structure
  lost, data kept.

- A pointer member: the address, and nothing else. Following it is precisely the
  read the instrumentation refuses to make -- nothing in `struct inner *` says
  the address is readable, that it points at one `inner` rather than none, or
  that the object is still alive. The kernel's read of the *outer* object is
  already `copy_from_kernel_nofault` for the same reason.

- Offline, outside the contract: word [1] of the record is the call site, so
  `addr2line -i` plus the binary's own DWARF -- or `pahole` on `vmlinux` --
  recovers the parameter's declared type and therefore every member's type and
  every nested layout. This needs the matching build, and the viewer does not
  do it.

What closing it would take -- five gaps, which do not all live on the same side
of the callback.

`offsets` *is* the table: a pointer into the instrumented module's `.rodata`
holding `2 * num_fields` words, laid out `{off0, size0, off1, size1, ...}`, with
`num_fields` as its only length. Both consumers index it identically:

```c
/* kernel: kcov_dataflow.c */
copy_from_kernel_nofault(&off, &offsets[i * 2],     sizeof(off));
copy_from_kernel_nofault(&sz,  &offsets[i * 2 + 1], sizeof(sz));

/* libFuzzer: FuzzerTracePC.cpp */
uint64_t Bytes = Offsets[I * 2 + 1];
if (Bytes > sizeof(uint64_t))
  Bytes = sizeof(uint64_t);
__builtin_memcpy(&Field, Object + Offsets[I * 2], Bytes);
```

So the per-field offset and size are fully available *to a consumer* -- a
userspace runtime holds the whole table in-process. The kernel loses not access
but forwarding. And the eight-byte clamp is a convention both consumers chose
independently, so a member wider than eight bytes is truncated for libFuzzer
too; it separately caps the loop at `kMaxDataflowFields` = 32.

Three of the five gaps therefore need no compiler change at all:

- **Kernel and UAPI.** Forward the per-field offsets and sizes into the record
  instead of consuming them, so a userspace reader can tell `{0, 1}` from
  `{4, 4}`. Costs record space per observation.

- **Kernel.** Stop silently truncating a member wider than eight bytes -- emit
  more than one word for it, or flag it. The true width is already in the table.

- **UAPI.** Widen the header's `size` field past its eight bits, or state that
  it saturates.

The other two cannot be fixed downstream, because the information is not in
`offsets` in the first place. Only DWARF has it, and neither consumer has DWARF
at the moment the callback fires:

- **Compiler, and therefore the ABI.** A per-field *kind* (integer, float,
  pointer, aggregate) so that eight bytes stops being ambiguous. Costs a third
  word per field, or spare bits in the size, and changes the table's shape for
  every existing consumer.

- **Compiler, and therefore the ABI.** A link from an aggregate field to that
  aggregate's own table, making `offsets` a tree rather than an array and the
  decode a walk rather than a loop. This also forces a decision the prototype
  has never had to make: a depth limit, and a policy for pointer members, since
  following one is an unbounded faultable read of attacker-influenced memory
  from instrumentation context -- a different risk from reading a field of an
  object the caller handed over.

The division sets the order of work. The three kernel-side items are local,
compatible changes to a format that is not yet anyone's stable ABI. The two
compiler-side items change what every runtime must understand, cost `.rodata`
per struct type, and would be hard to retract. Whether a dataflow signal needs
the depth at all, or whether one level of fields is the useful stopping point,
is an open question rather than a settled answer -- today it is an accident of
the format.

# LLVM Series Structure

```mermaid
flowchart TD
    A["Patch 1/5<br/>LLVM instrumentation"] --> B["Patch 2/5<br/>Clang options"]
    B --> C["Patch 3/5<br/>compiler-rt runtime"]
    C --> D["Patch 4/5<br/>libFuzzer value profile"]
    D --> E["Patch 5/5<br/>Public documentation"]
```

1. What values are observed? How are they represented?
2. How does a user enable the instrumentation?
3. What links when nobody consumes the callbacks?
4. How are the callbacks consumed in userspace?
5. What does the public interface promise?

Each patch adds one finished layer, so every commit is internally
ABI-consistent. An earlier six-patch version was not: patch 1 introduced an
address-based ABI with spilling and patch 2 undid it, leaving reviewers to argue
about a design the series had already abandoned.

Note on the current tree state: the frame work and the identity change are
presently folded into patch 5, the documentation commit. Before posting, the
pass changes belong in patch 1 and the signature changes in patches 3 and 4, so
that the above property holds again.


# Two New SanitizerCoverage Modes

LLVM patch introduces:
- trace-args: At the start of every frame, as early as the reported values permit
- trace-ret: Before instrumentable returns

Clang exposes them through: `-fsanitize-coverage=trace-args,trace-ret`

```
foo(a, b)
│
├── trace_args(arg0, a)
├── trace_args(arg1, b)
│
│   function body
│
└── trace_ret(result)
```

A musttail return is not instrumented because LLVM requires the tail call and return to remain adjacent.

Both hang off `instrumentFunction()`, after the inliner, and between them they
reach every function the patch adds to the pass. The argument side enumerates;
the return side scans.

```mermaid
flowchart TD
    E["instrumentFunction(F)<br/>after the inliner"]

    E -->|"Options.TraceArgs"| A1["InjectTraceForArgs(F, DT)"]
    E -->|"Options.TraceRet"| R1["InjectTraceForRet(F)"]

    A1 --> A2["collectInlineFrames(): frame 0 is F's own body,<br/>starting at EntryBB.getFirstInsertionPt()"]
    A2 --> A3["walk every instruction's DebugLoc::getInlinedAt():<br/>one further frame per distinct call site,<br/>outermost first"]
    A3 --> A4["walk every DbgVariableRecord:<br/>route to a frame by getInlinedAt(),<br/>key by DILocalVariable::getArg()"]
    A4 --> A5["injectTraceForFrame(), once per frame"]
    A5 --> A6["push the insertion point past every reported<br/>definition in the block, then clamp back<br/>with legalInsertionPt()"]
    A6 --> A7["replace the synthetic !dbg with the frame's own:<br/>DILocation(SP->getScopeLine(), SP, InlinedAt)"]
    A7 --> A8["for Idx = 1 .. max(getNumDeclaredParams(SP),<br/>highest getArg() seen): emit one call,<br/>size 0 where the parameter has no usable value"]

    R1 --> R2["for each BasicBlock: is the terminator<br/>a ReturnInst? unwinding carries no value"]
    R2 --> R3["is the node before it a musttail call?<br/>then skip: it must stay adjacent to the ret"]
    R3 --> R4["insert immediately before the ReturnInst"]
    R4 --> R5["report RI->getReturnValue(), or the sret<br/>Argument when the IR signature returns void"]
    R5 --> R6["one call per return site, F's own frame only"]

    NR["no frame walk here: an inlined callee has<br/>no ReturnInst left, and no debug record<br/>describes a return value"]
    NR -.- R1
```

The asymmetry is the point. trace-args has to ask debug metadata *what to
report and how many times*, because the IR argument list no longer answers
either question. trace-ret asks the IR directly -- a `ReturnInst` is a
`ReturnInst` -- and consults debug metadata only for the declared return type,
to build a field table.

Every operand of both callbacks, and the query that produces it:

| Callback operand | Where it comes from, on the LLVM side |
| --- | --- |
| `arg_idx` | `DILocalVariable::getArg() - 1`, assigned by the frontend before ABI lowering; positionally from `F.args()` when there are no records |
| how many calls | `getNumDeclaredParams()`, the length of `DISubroutineType`'s type array, widened to the highest `getArg()` actually seen |
| `val` | a `Value` the function already computes: a debug record's operand, an `Argument`, or `ReturnInst::getReturnValue()` -- cast, never loaded |
| `size` | `DataLayout` for a pointer, the IR type's bit width for a number, `DICompositeType::getSizeInBits()` for an object reported by address |
| `offsets`, `num_fields` | `DW_TAG_member` entries of the parameter's or return value's `DICompositeType`, interned per type |
| which frame a call speaks for | `DILocation::getInlinedAt()`, both to discover the frame and to stamp the call's own `!dbg` so the return address resolves to it |
| where the call goes | the IR: `getFirstInsertionPt()`, the dominance of each reported definition, and the position of each `ReturnInst` |

Four of the seven rows are debug metadata, which is what
"Debug Information Defines the Source View" below is about.

Neither callback is told which function it speaks for. A runtime that needs to
know takes its own return address, less one so the address lies within the call
rather than on the instruction after it. This is the same convention the
existing trace-cmp callbacks use, and it is what lets the pass report inlined
callees.

# Inlined Callees Are Frames, Not Losses

The pass runs after the inliner. A callee that was inlined has no symbol, no
entry block, and often no `Function` object left at all.

An earlier version of this work treated that as a loss and discarded every
observation coming from inlined code. The answer to "then I cannot see my
callee's arguments" became `-fno-inline`, which is a bad answer:

1. It changes the code generation of the thing being measured.
2. On a whole Linux kernel it does not build. Some code relies on the inliner to
   fold a constant into an inline asm `"i"` operand:
   `arch/x86/include/asm/jump_label.h:37:11: error: invalid operand for inline asm constraint 'i'`

The compiler side should not ask the kernel to change shape so that an
instrumentation workaround keeps working.

What is left of an inlined callee is a range of instructions that debug
information still describes precisely. That is enough.

```mermaid
flowchart TD
    S["caller(size, p)<br/>after inlining"] --> F1["frame 1: caller<br/>InlinedAt = null"]
    S --> F2["frame 2: mid<br/>InlinedAt = caller:20"]
    S --> F3["frame 3: leaf<br/>InlinedAt = mid:15"]
    F1 --> C1["trace_args, entry block"]
    F2 --> C2["trace_args, in mid's range"]
    F3 --> C3["trace_args, in leaf's range"]
    F1 --> R["trace_ret: frame 1 only"]
```

Each frame:

1. Reports its own subprogram's parameters, in its own `arg_idx` numbering
2. Traces them from inside its own instruction range
3. Carries a synthetic `DILocation` whose scope is the callee and whose
   `inlinedAt` is the call site

That last point is what makes the identity scheme work: the trace call inherits
the frame's place in the debug line table, so `addr2line -i` on the recorded
address recovers the whole chain.

```
frame 1  ra-1 -> caller:19
frame 2  ra-1 -> mid:14
                 caller:20        (inlined at)
frame 3  ra-1 -> leaf:9
                 mid:15           (inlined at)
                 caller:20        (inlined at)
```

One callee inlined at two call sites is two frames: each ran with its own
arguments.

Frames are discovered by walking the whole `inlinedAt` chain of every
instruction, not just one level. That recovers a frame whose own code the
optimizer folded away while leaving the code it had inlined behind -- a common
shape for a small wrapper. On the test case above it took the reported frame
count from one to three.

Two limits follow from running this late:

1. A frame whose code the optimizer removed entirely is not reported: there is
   no address range left to report it from.
2. Returns are reported for the surviving function only. An inlined callee has
   no `ret` instruction, and no debug record describes a return value the way
   `DILocalVariable` describes a parameter. Faking one would mean guessing.

Consequence for the kernel: `-fno-inline` is no longer needed to observe small
callees. `CONFIG_KCOV_DATAFLOW_NO_INLINE` survives as a per-object convenience
-- it makes records resolvable with plain kallsyms instead of requiring
inline-aware symbolisation -- and deliberately does not follow from
`CONFIG_KCOV_DATAFLOW_INSTRUMENT_ALL`.

Two of the eight IR tests are specifically about frames:
`trace-args-inline-frames.ll` for a frame that still has code, including the
recovered middle frame whose own code folded away, and `trace-args-inlined.ll`
for the complementary case -- a frame with no code left, which must not be
reported and whose records must not leak into the enclosing function's
parameters. Both also prove the emitted IR is well-formed, since `opt` runs the
verifier and a kernel build does not. That is the class of bug this work
actually produced: an insertion point among a block's PHI nodes, which raised no
verifier complaint in the kernel build and crashed instruction selection on
`kernel/sys.c` instead, with no useful diagnostic.

# Control-Flow Levels and Value Tracing Are Orthogonal

func, bb, and edge describe control-flow coverage granularity.
- func: Which function executed?
- bb: Which basic block executed?
- edge: Which control-flow transition executed?

trace-args answers a different question. Which values entered this frame?

```mermaid
flowchart TD
    A["Frame start"] --> B["trace_args(arg0)"]
    B --> C["trace_args(arg1)"]
    C --> D{"Branch"}
    D --> E["Basic block A"]
    D --> F["Basic block B"]
```

Changing func, bb, or edge does not move trace-args to those locations.

When no explicit coverage level is provided, the current Clang driver selects edge as the internal default level. This does not mean argument callbacks are inserted on every edge or that trace-pc-guard is automatically enabled.

# Why Argument Tracing Is Not Trivial

The source signature may differ from the LLVM IR signature.

`struct Big foo(int mode);`

After ABI lowering
define void @foo(
    ptr sret(%struct.Big) %result,
    i32 %mode)

```mermaid
flowchart TD
    A["Source signature"] --> B["ABI lowering"]
    B --> C["Hidden sret pointer"]
    B --> D["Visible scalar argument"]
    B --> E["Split or coerced aggregates"]
```

The compiler must decide whether callback identity represents:

`source-level parameters` or `lowered IR / ABI arguments`

The current prototype attempts to recover source-level parameter identity when usable debug records are available, and does so per frame -- an inlined callee's parameters are numbered in its own space, not its caller's.

# Design Principle: Values Remain Values

Values remain values. Only objects that already exist in memory are reported by address.

```mermaid
flowchart TD
    A["Observed runtime information"] --> B{"Existing structured object<br/>in memory?"}
    B -->|"No"| C["Convert value to u64"]
    B -->|"Yes"| D["Use object address<br/>and field layout"]
    C --> E["Callback"]
    D --> E
```

For direct values:

```
integer        → zero-extend or truncate
pointer        → ptrtoint
floating point → bit pattern
```

The pass does not introduce an alloca merely to report a value.

Compiler side, that whole conversion is one function, `getReportedValue()`, and
every box below is a cast:

```mermaid
flowchart TD
    V["a Value the pass already has:<br/>a debug record operand,<br/>an IR Argument,<br/>or a ReturnInst operand"]

    V --> RV["getReportedValue()"]

    RV -->|"pointer"| PT["CreatePtrToInt<br/>size = DL.getPointerSize()"]
    RV -->|"number"| NUM["CreateBitCast if float,<br/>then CreateZExt,<br/>or CreateTrunc to i64<br/>above 64 bits<br/>size = ceil(bits / 8)"]
    RV -->|"neither"| NR["vector, token, or an<br/>in-register aggregate:<br/>return {nullptr, 0}"]

    PT --> OUT["val and size<br/>for the callback"]
    NUM --> OUT
    NR --> ZERO["size = 0:<br/>reported, with no value"]

    AGG["getReportedValues() splits a<br/>struct or array first, with<br/>CreateExtractValue: the<br/>elements share no address,<br/>so each gets its own callback"]
    AGG -.- RV

    N["no alloca, no load, no store:<br/>every step above is a cast"]
    N -.- OUT
```

The input side is the part worth dwelling on: the pass never produces a value,
it only takes one the function already computed. On the argument side that is a
debug record's operand, or an `Argument` when there are no records; on the
return side it is `ReturnInst::getReturnValue()`, or the `sret` argument when
the IR signature returns nothing.

# Current Callback ABI

```c
void __sanitizer_cov_trace_args(
    uint32_t arg_idx,
    uint32_t size,
    uint64_t val,
    uint64_t *offsets,
    uint32_t num_fields);

void __sanitizer_cov_trace_ret(
    uint32_t size,
    uint64_t val,
    uint64_t *offsets,
    uint32_t num_fields);
```

There is no `pc` argument. An earlier version had one, carrying the address of
the instrumented function; it was removed when the pass started reporting
inlined callees, because an inlined callee has no address to put in it.
Substitutes were tried and rejected: a per-frame descriptor global would have
redefined what `pc` meant for existing consumers, and a `BlockAddress` or
`__sancov_pcs` entry per frame pins basic blocks and therefore perturbs code
generation -- defeating the reason for running after the inliner rather than
before it.

Identity is now the callback's own return address, less one:

```c
/* kernel/kcov_dataflow.c */
#define KCOV_DF_CALL_SITE(ret_ip)	((ret_ip) - 1)

/* compiler-rt/lib/fuzzer/FuzzerTracePC.cpp */
uintptr_t PC = reinterpret_cast<uintptr_t>(GET_CALLER_PC()) - 1;
```

The minus one is not tidiness. An inlined body is a bounded instruction range,
and a trace call that is the last thing in that range has a return address one
past its end, which belongs to the next frame. Without the adjustment the
record names the wrong function.

## The Same Contract, Written Out as Calls

The interpretation rule below is the form a consumer should ultimately hold in
its head. It is also the form in which two things are easy to miss: that
`arg_idx` has no counterpart on the return side at all, and that `trace_ret`
has cases of its own that the rule does not mention. So the same ground is
covered twice -- first concretely, as calls the compiler actually emits, then
as the rule. The duplication is deliberate.

```c
struct S   { int a; long b; };          /* 16 bytes, layout known: {0,4} {8,8}  */
struct Big { long x; long y; long z; }; /* 24 bytes: too large for registers    */

void      submit(struct S *s, int flags, void *token); /* void return      */
struct S *lookup(struct S *tab, int id);               /* struct pointer   */
int       flags_of(struct S *s);                       /* direct scalar    */
void     *opaque_of(struct S *s);                      /* opaque pointer   */
struct Big make_big(int seed);                         /* sret object      */
```

Five declarations covering every shape the contract has, the hidden `sret`
pointer included. What follows is the whole of what
`clang -O1 -g -fno-inline
-fsanitize-coverage=trace-pc-guard,trace-args,trace-ret` emits for them --
every `trace_args` and every `trace_ret` call, verbatim, with function
attributes trimmed and the bodies and `trace_pc_guard` calls elided:

```llvm
@__sancov_offsets_   = private unnamed_addr constant [4 x i64]
                         [i64 0, i64 4, i64 8, i64 8]
@__sancov_offsets_.5 = private unnamed_addr constant [6 x i64]
                         [i64 0, i64 8, i64 8, i64 8, i64 16, i64 8]

define void @submit(ptr %0, i32 %1, ptr %2) {
  %4 = ptrtoint ptr %0 to i64
  call void @__sanitizer_cov_trace_args(i32 0, i32 16, i64 %4,
                                        ptr @__sancov_offsets_, i32 2)
  %5 = zext i32 %1 to i64
  call void @__sanitizer_cov_trace_args(i32 1, i32 4, i64 %5, ptr null, i32 0)
  %6 = ptrtoint ptr %2 to i64
  call void @__sanitizer_cov_trace_args(i32 2, i32 8, i64 %6, ptr null, i32 0)
  ...
  call void @__sanitizer_cov_trace_ret(i32 0, i64 0, ptr null, i32 0)
  ret void
}

define ptr @lookup(ptr %0, i32 %1) {
  %3 = ptrtoint ptr %0 to i64
  call void @__sanitizer_cov_trace_args(i32 0, i32 16, i64 %3,
                                        ptr @__sancov_offsets_, i32 2)
  %4 = zext i32 %1 to i64
  call void @__sanitizer_cov_trace_args(i32 1, i32 4, i64 %4, ptr null, i32 0)
  ...
  %7 = ptrtoint ptr %6 to i64
  call void @__sanitizer_cov_trace_ret(i32 16, i64 %7,
                                       ptr @__sancov_offsets_, i32 2)
  ret ptr %6
}

define i32 @flags_of(ptr %0) {
  %2 = ptrtoint ptr %0 to i64
  call void @__sanitizer_cov_trace_args(i32 0, i32 16, i64 %2,
                                        ptr @__sancov_offsets_, i32 2)
  ...
  %4 = zext i32 %3 to i64
  call void @__sanitizer_cov_trace_ret(i32 4, i64 %4, ptr null, i32 0)
  ret i32 %3
}

define ptr @opaque_of(ptr %0) {
  %2 = ptrtoint ptr %0 to i64
  call void @__sanitizer_cov_trace_args(i32 0, i32 16, i64 %2,
                                        ptr @__sancov_offsets_, i32 2)
  ...
  %6 = ptrtoint ptr %5 to i64
  call void @__sanitizer_cov_trace_ret(i32 8, i64 %6, ptr null, i32 0)
  ret ptr %5
}

define void @make_big(ptr sret(%struct.Big) %0, i32 %1) {
  ; the sret pointer is not a source parameter, so `seed` keeps arg_idx 0
  %3 = zext i32 %1 to i64
  call void @__sanitizer_cov_trace_args(i32 0, i32 4, i64 %3, ptr null, i32 0)
  ...
  ; the IR returns void; the buffer is reported as the struct it holds
  %11 = ptrtoint ptr %0 to i64
  call void @__sanitizer_cov_trace_ret(i32 24, i64 %11,
                                       ptr @__sancov_offsets_.5, i32 3)
  ret void
}
```

Two tables -- one per struct type, interned and shared -- eight argument
callbacks, five return callbacks, and no `alloca` anywhere in the output.

Note what `make_big` demonstrates that the other four cannot. Its IR takes two
arguments and returns `void`; the source takes one and returns a struct. The
argument callback reports `seed` as `arg_idx 0`, not 1, because the `sret`
pointer has no source-level counterpart; the return callback reports that same
pointer as a 24-byte object with three fields, so the return does not vanish.
Both halves of that are source fidelity rather than ABI fidelity.

```mermaid
flowchart LR
    AR["__sanitizer_cov_trace_args<br/>(arg_idx, size, val,<br/>offsets, num_fields)"]
    RT["__sanitizer_cov_trace_ret<br/>(size, val,<br/>offsets, num_fields)"]

    AR -->|"arg_idx names the source<br/>parameter; one call per<br/>parameter, in order"| T
    RT -->|"no index: one logical<br/>return value per frame"| T

    T["the four<br/>shared fields"]

    T --> E["nothing to report<br/>size = 0, val = 0<br/>offsets = NULL, num_fields = 0<br/>args: a parameter the optimizer dropped<br/>ret: a void function"]
    T --> D["direct scalar<br/>size = 4, val = 42<br/>offsets = NULL, num_fields = 0<br/>the datum is already in the record;<br/>no memory is touched"]
    T --> O["opaque pointer<br/>size = 8, val = the pointer<br/>offsets = NULL, num_fields = 0<br/>the pointer value itself is the datum;<br/>the pointee is never read"]
    T --> S["struct with known layout<br/>size = 16, the whole object<br/>val = object address<br/>offsets = {0,4},{8,8}, num_fields = 2<br/>read those fields at val"]
```

## The Four Shapes

## __sanitizer_cov_trace_args

```c
__sanitizer_cov_trace_args(
    0,                  /* arg_idx:    source parameter 0, `s`          */
    16,                 /* size:       sizeof(struct S), not of the ptr */
    (uint64_t)s,        /* val:        the object's address             */
    __sancov_offsets_,  /* offsets:    {0,4},{8,8}                      */
    2                   /* num_fields: two fields to read at val        */
);

__sanitizer_cov_trace_args(
    1,                  /* arg_idx:    source parameter 1, `flags`      */
    4,                  /* size:       sizeof(int)                      */
    42,                 /* val:        the value itself                 */
    NULL,               /* offsets:    none                             */
    0                   /* num_fields: val is the datum                 */
);

__sanitizer_cov_trace_args(
    2,                  /* arg_idx:    source parameter 2, `token`      */
    8,                  /* size:       sizeof(void *)                   */
    (uint64_t)token,    /* val:        the pointer, not the pointee     */
    NULL,               /* offsets:    no known layout to describe      */
    0                   /* num_fields: val is the datum                 */
);
```

## __sanitizer_cov_trace_ret

No value -- a `void` function, or a parameter the optimizer erased:

```c
__sanitizer_cov_trace_ret(
    0,    /* size:       no return value */
    0,    /* val:        no return value */
    NULL, /* offsets                     */
    0     /* num_fields                  */
);
```

`submit` returns nothing and the callback is emitted anyway. A consumer must
read it as *the function returned*, not as *the function returned zero*: the
discriminator is `size == 0`, never `val == 0`. The argument side produces the
same shape for a different reason -- a parameter with no debug record left is
reported with `size 0` so that the parameter list stays complete.

Direct scalar -- `flags` in `submit`, the return of `flags_of`:

```c
size       = 4             /* bytes of val that matter */
val        = 42            /* the value itself         */
offsets    = NULL
num_fields = 0
/* -> record the argument, or the return value, as 42 */
```

The instrumentation widens the value -- `zext` for an integer, `ptrtoint` for a
pointer, `bitcast` for a `double` -- and hands over the bits. No object, no
table, no memory read by anyone. This is the overwhelmingly common case.

Pointer to a struct whose layout is known -- parameter 0 of the four functions
that take a `struct S *`, and the return of `lookup`:

```c
size       = 16            /* sizeof(struct S), not sizeof(ptr) */
val        = &object       /* the object's address              */
offsets    = {0,4},{8,8}   /* {byte offset, byte size} pairs    */
num_fields = 2
/* -> record the fields found at that address */
```

`size` is the size of the pointee, which is the one place the contract's own
naming stops matching its contents; the pointer value appears nowhere in the
record, only the address it holds, as `val`. The table is emitted once per
struct type per module and interned, so every site referring to `struct S`
shares the one `@__sancov_offsets_` above. Reading the fields is the consumer's
job and the consumer's risk.

The same shape, reached the other way -- `make_big`, whose struct comes back
through a caller-provided buffer:

```c
__sanitizer_cov_trace_ret(
    24,                   /* size:       sizeof(struct Big)          */
    (uint64_t)sret_buf,   /* val:        the caller's buffer          */
    __sancov_offsets_.5,  /* offsets:    {0,8},{8,8},{16,8}           */
    3                     /* num_fields: three fields to read at val  */
);
```

Not a fifth shape: it is the object-by-address shape again, and a consumer
decodes it with exactly the same branch. What differs is only how the compiler
arrived there. The IR function returns `void`, so there is no return value to
widen, and the pass reports the `sret` argument instead -- which means it has to
know the *declared* return type, the one debug query `trace-ret` makes.

Opaque pointer -- `token` in `submit`, the return of `opaque_of`:

```c
size       = 8             /* sizeof(void *) */
val        = the pointer   /* not the pointee */
offsets    = NULL
num_fields = 0
/* -> record the pointer value itself */
```

Indistinguishable from a direct scalar once it is in the record, and that is
correct: with no layout to describe there is nothing to dereference, and the
instrumentation does not dereference it. Note that `size` here is the size of
the pointer -- the exact opposite of the previous case, for an argument that
looks the same in the source. That is why a consumer must branch on
`num_fields` before it interprets either field.

## What Only trace-args Has

- `arg_idx`, counting source parameters from zero in the order they were
  written. `submit` produces indices 0, 1, 2 -- one call per parameter, always,
  whatever shape the value turned out to have.

- Hidden ABI arguments do not consume an index. `make_big` above is the case:
  `struct Big make_big(int seed)` lowered to `void @make_big(ptr sret, i32 %1)`,
  and `seed` is reported as `arg_idx 0`, not 1.

- The index is per frame, not per function. After inlining, an inlined callee's
  first parameter is its own `arg_idx 0`, unrelated to the caller's.

- A struct passed by value that the ABI split across registers emits several
  calls *sharing one* `arg_idx`, because the source had one parameter.

## What Only trace-ret Has

- No index, and therefore no way to say which of several callbacks belong
  together. That matters because a function with several `ret` instructions gets
  a callback before each one: these are alternatives, not a list, and a consumer
  sees at most one of them per invocation.

- The `void` case above, which has no argument-side equivalent in meaning even
  though it has one in shape.

- A struct returned by value through a caller-provided `sret` buffer is reported
  as an object: that buffer's address, the source struct's size, its field
  table -- `make_big` above. The IR function returns `void`, so without this the
  return would simply vanish.

- A struct small enough to come back in registers has no address, so it is
  reported as one direct-scalar callback per register piece. With no `arg_idx`
  to share and no piece index in the signature, those calls are observable but
  not reassemblable.

- A `musttail` call must stay adjacent to the `ret` that forwards it, so there
  is nowhere to put the callback and none is emitted. The return is silently
  unobserved -- the one case where a consumer cannot tell the difference between
  a function that was not instrumented and one that was.

## Main Interpretation Rule

```mermaid
flowchart TD
    A["Callback"] --> B{"size == 0?"}
    B -->|"Yes"| C["Value unavailable"]
    B -->|"No"| D{"num_fields == 0?"}
    D -->|"Yes"| E["val is the direct value"]
    D -->|"No"| F["val is an object address"]
    F --> G["offsets describes its fields"]
```

val == 0 must not be used as an unavailable marker because zero is a valid argument, return value, or null pointer.

# What Each Callback Field Means

- arg_idx: Zero-based source parameter index, when recoverable
  Numbered within the frame it belongs to, so an inlined callee's parameter 0 is
  its own and not its caller's
  Absent from trace-ret because a source function has one logical return value

- size: Number of meaningful bytes
  0 means that no value could be reported

- val

  num_fields == 0: direct value
  num_fields > 0: object address

- offsets: {byte offset, byte size} pairs

- num_fields: Field count and currently also the discriminator between a direct value and an object address

Not a field, but part of the contract:

- the recorded location: the callback's own return address, less one

  Resolved with inline information (`addr2line -i`) it names the inlined callee
  that reported the value and the chain it was inlined through

  Resolved with a plain symbol table it names only the function the code was
  merged into -- a real loss of resolution, and the one cost the identity change
  pushes onto consumers

  It is still not a dynamic invocation identity: two recursive calls remain
  indistinguishable

# Structured Return Values Are Observable

trace-ret supports both major ABI return strategies.

Indirect return through sret
```mermaid
flowchart LR
    A["Source struct return"] --> B["ABI lowering"]
    B --> C["Caller-provided sret buffer"]
    C --> D["trace_ret"]
    D --> E["Object address + field offsets"]
```

Example representation:
```
size       = sizeof(struct Big)
val        = sret buffer address
num_fields = number of fields
offsets    = struct layout
```

Register-returned aggregate
```mermaid
flowchart TD
    A["Source struct return"] --> B["ABI register pieces"]
    B --> C["Piece A"]
    B --> D["Piece B"]
    C --> E["trace_ret"]
    D --> F["trace_ret"]
```

The values are observable, but the current callback does not include:

- piece index
- source offset
- total piece count
- source field identity


Structured return support and the register-piece behavior are explicitly tested in the LLVM patch.

# Debug Information Defines the Source View

Source-level argument mapping currently uses debug records, and the two modes
ask debug metadata for different things.

```mermaid
flowchart TD
    A["Source function"] --> B["Frontend"]
    B --> C["ABI-lowered LLVM IR"]
    B --> D["Debug metadata"]
    C --> E["Runtime LLVM values"]

    D --> F["DILocalVariable::getArg()"]
    D --> I["DILocation::getInlinedAt()"]
    D --> J["DISubroutineType<br/>getTypeArray()[0]:<br/>the declared return type"]
    D --> M["DICompositeType members<br/>-> getFieldOffsets()"]

    E --> G["trace-args"]
    F --> G
    I --> G
    M --> G
    G --> H["Source-level arg_idx, per frame,<br/>field tables for known layouts"]

    E --> K["trace-ret"]
    J --> K
    M --> K
    K --> L["One logical return per function frame,<br/>field table for the declared return type"]
```

trace-args makes three debug queries: `DILocalVariable::getArg()` for the index,
`DILocation::getInlinedAt()` to discover that an inlined callee is there to
report at all, and the member list of a `DICompositeType` for a field table.

trace-ret makes exactly one, `getDeclaredReturnType()`:

```cpp
static DIType *getDeclaredReturnType(DISubprogram *SP) {
  if (!SP || !SP->getType() || SP->getType()->getTypeArray().empty())
    return nullptr;
  return SP->getType()->getTypeArray()[0];
}
```

It needs no `DILocalVariable`, because there is no index to recover, and it
deliberately asks nothing about inlining. The declared return type then feeds
the same `getFieldOffsets()` the argument side uses, which is why one
`@__sancov_offsets_` table serves both modes for a given struct.

What trace-ret does not get from debug metadata is frames:

```c
/* InjectTraceForRet() */
// Only F's own frame is reported here. A callee the inliner merged into F has
// no return instruction left - its result became an ordinary value of F - and
// no debug record describes a return value the way DILocalVariable describes a
// parameter, so there is nothing to key an inlined return on. Arguments of
// inlined frames are still reported; see collectInlineFrames().
```

So richer debug information widens what trace-args sees and does not widen what
trace-ret sees. Inlining a callee adds argument records and adds no return
record.

The instrumentation remains usable without -g, but its abstraction level changes.

Without debug information, trace-args/trace-ret still observe concrete LLVM IR values without manufacturing memory. Field tables generally unavailable

A build without -g also has no debug locations, so it discovers no inlined
frames: one frame, the function's own body, reported positionally from its IR
argument list. This is not a special case bolted on; it falls out of the same
loop, which is why the no-debug behaviour did not change when frames were added.

On the return side the loss is uneven, and one case is worse than anything on
the argument side. With no declared return type there is no field table, and for
an indirect return there is also no size, so the value is not reported at all.
This is the same five functions as above, compiled without `-g` and otherwise
identically:

```llvm
; clang -O1 -fno-inline
;       -fsanitize-coverage=trace-pc-guard,trace-args,trace-ret
; no @__sancov_offsets_ global is emitted at all

define void @make_big(ptr sret(%struct.Big) %0, i32 %1) {
  ; the sret pointer is still skipped: `seed` keeps arg_idx 0 even here
  call void @__sanitizer_cov_trace_args(i32 0, i32 4, i64 %3, ptr null, i32 0)
  ; but the return is dropped: size 0, indistinguishable from a void function
  call void @__sanitizer_cov_trace_ret(i32 0, i64 0, ptr null, i32 0)
}

define void @submit(ptr %0, i32 %1, ptr %2) {
  ; the struct pointer degrades to the pointer: 16 -> 8, table -> null
  call void @__sanitizer_cov_trace_args(i32 0, i32 8, i64 %4, ptr null, i32 0)
  call void @__sanitizer_cov_trace_args(i32 1, i32 4, i64 %5, ptr null, i32 0)
  call void @__sanitizer_cov_trace_args(i32 2, i32 8, i64 %6, ptr null, i32 0)
  call void @__sanitizer_cov_trace_ret(i32 0, i64 0, ptr null, i32 0)
}

define ptr @lookup(ptr %0, i32 %1) {
  call void @__sanitizer_cov_trace_args(i32 0, i32 8, i64 %3, ptr null, i32 0)
  call void @__sanitizer_cov_trace_args(i32 1, i32 4, i64 %4, ptr null, i32 0)
  ; the object return degrades the same way: 16 -> 8
  call void @__sanitizer_cov_trace_ret(i32 8, i64 %7, ptr null, i32 0)
}

define i32 @flags_of(ptr %0) {
  call void @__sanitizer_cov_trace_args(i32 0, i32 8, i64 %2, ptr null, i32 0)
  ; a scalar return is unaffected
  call void @__sanitizer_cov_trace_ret(i32 4, i64 %4, ptr null, i32 0)
}

define ptr @opaque_of(ptr %0) {
  call void @__sanitizer_cov_trace_args(i32 0, i32 8, i64 %2, ptr null, i32 0)
  ; an opaque pointer was already shapeless: unaffected
  call void @__sanitizer_cov_trace_ret(i32 8, i64 %6, ptr null, i32 0)
}
```

Four things to read out of that. `make_big`'s return becomes `size == 0`,
because the buffer is a struct in memory rather than a value that fits in a
register, and with no declared type there is nothing to say how much of it to
read. Its `sret` pointer is nevertheless still skipped, so `arg_idx` numbering
survives with no debug information at all -- that part never depended on it.
Every `struct S *` argument and the `lookup` return fall back from a 16-byte
object to an 8-byte pointer, which is the documented degradation. And a scalar
return and an opaque pointer are untouched, because neither ever needed a type.
The argument side has no equivalent of the dropped return: it still reports
every parameter the IR declares, positionally.

The no-debug fallback is generally safer than attempting incomplete source reconstruction, but its ABI-level semantics should be documented and tested explicitly.

That is not yet true of the return side. `trace-args-no-debug.ll` pins the
argument behaviour; there is no corresponding test for trace-ret, so the
dropped-sret case above is current behaviour rather than agreed behaviour.

The frame work raises the stakes here rather than changing the answer. Debug
metadata is now not only how arg_idx is derived but how an inlined callee is
discovered at all, so the set of functions a build observes depends on how well
debug locations survived optimisation. The counter-argument is that the
information is not available anywhere else: after the inliner, debug metadata is
the only record that the callee ever existed.


# What We Need to Agree On

## Linux integration

1. New KCOV mode? Separate KCOV-dataflow facility?

2. More general value-observation infrastructure?

## Compiler callback ABI

1. Abstraction level:
   Source-level parameter values? or ABI / IR-level values?
   Is usable debug metadata an acceptable input to runtime instrumentation semantics?
   It now decides not only arg_idx but which functions are observed at all.

2. Callback representation:
   Should num_fields serve as both field count and value/address discriminator?

3. Field description:
   Should a field describe what it is, and what it contains?
   `{byte offset, byte size}` carries no type and does not nest, so five members
   of eight bytes -- a double, an inline struct, a pointer to a known struct, an
   opaque pointer, a long -- arrive identically described, and a member that is
   itself a struct arrives as one opaque blob whose own layout the module
   already holds. A per-field kind, and a link from an aggregate field to that
   aggregate's table, would fix both. Both are compiler-side and both change the
   table for every consumer; one level may be the right stopping point, but it
   is currently an accident of the format rather than a decision.

4. Is value width uint64_t sufficient? How should values wider than 64 bits be represented?

5. Identity:
   Is a return address the right identity for an instrumentation callback?
   It is what makes inlined frames reportable and it matches trace-cmp, but it
   requires the consumer to resolve an address -- and to resolve it *well*
   requires inline-aware symbolisation. May an ABI assume that of its consumers?

## Kernel mmap UAPI

1. Are 8-bit size and arg_idx fields sufficient?
   An object larger than 255 bytes reports a clamped size, with no flag.

2. How should structured RET values be represented?

3. Should the record forward the field table rather than consume it?
   `kcov_df_write()` reads the compiler's `{offset, size}` pairs and writes only
   the values, so a userspace reader receives N opaque u64s: it cannot tell a
   1-byte field from a 4-byte one, and an inline member wider than 8 bytes is
   silently truncated to its first 8. All of this is fixable kernel-side without
   touching the callback ABI, at the cost of record space.

4. Should call or return instances have explicit identifiers?

5. Loss reporting: there is no dropped-record counter. A full buffer is
   indistinguishable from a short capture. Reporting inlined frames multiplies
   the record rate, so this stopped being theoretical: a selftest trigger filled
   a 1M-word buffer and the missing tail surfaced as four failed assertions
   rather than as a diagnostic, and the binderfs selftest currently *passes*
   while running three words short of filling its own buffer.

## Runtime policy

1. Runtime memory access:
   Does type/layout metadata provide enough justification for reading an object? Who owns lifetime and fault-safety policy?

# Desired Outcome

The prototype already demonstrates an end-to-end path.

```mermaid
flowchart TD
    A["Clang / LLVM"] --> B["Function arguments<br/>and returned values"]
    B --> C["Current callback ABI"]
    C --> D["Linux KCOV-dataflow"]
    C --> E["compiler-rt / libFuzzer"]
    D --> F["Kernel fuzzing"]
    E --> G["Userspace fuzzing"]
    F --> H["Design evidence"]
    G --> H
    H --> I["Upstream agreement"]
```

Today’s goal is to define the upstream direction before treating the prototype ABI as permanent.