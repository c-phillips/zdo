---
status: done
tags: [todo,]
priority: 0
---
# complete mark command
- [ ] Task index registry
    - [ ] Index specific to each `task` directory
- [ ] Task selection via index registry

## Task Index:
The index should assign a unique id number to a filepath. 
If a file is removed, the index number should be freed and available for reassignment.
Indices should NEVER be shuffled: the same path should retain the same index^[0].
Each `task` directory should retain its own index registry.
Combining registries will prefix the id, e.g. `2 -> a2`.
Global tasks have a reserved prefix: `_2`.


[0] Within a relative index registry