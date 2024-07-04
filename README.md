![zdo_logo](doc/zdo_logo_header.png#gh-light-mode-only)
![zdo_logo](doc/zdo_logo_header_darkmode.png#gh-dark-mode-only)

Cross-platform CLI Task Manager using Markdown

No lock-in, no worries

## Install
This project uses Zig 0.13.0 for now. You can get it from [here](https://ziglang.org/download).

To build the executable for use, run
```bash
zig build -Drelase=true
```
Then add it to your system path or `bin` directory.

In the future, this repository may host prebuilt binaries for easier installation.


## How to use it
See all the commands with `zdo help` or you can get started right away by adding your first task:
```bash
zdo add Get better at programming +ci --priority 3
```
You'll see that a new markdown file was created in a local `.tasks` directory. It contains a few yaml front-matter items that are useful for tracking with zdo, obsidian, or whatever else you'd like.
```md
---
priority: 3
status: pending
tags: [ci,]
---
# Get better at programming
```

> ✏ Note: The first `# Heading Level 1` line will be used for the task name

You can edit this file and add whatever you'd like to it. Here's an example task for this very project:
```md
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
Indices should NEVER be shuffled: the same path should retain the same index^[0].
Each `task` directory should retain its own index registry.
Combining registries will prefix the id, e.g. `2 -> a2`.
Global tasks have a reserved prefix: `_2`.


[0] Within a relative index registry
```

The `.tasks` directory is also where all of your task files will live together in anarchy! No wait, you can actually establish a hierarchy and your tasks will be grouped accordingly.

To see all of your tasks just use:
```
~$ zdo list

#     ?   !  Task
________________________________________________________________________________

0    [-]  .  This is an example task                             Due 14d ago
1    [x]  .  complete mark command                               Anytime
2    [z]  .  waiting task                                        Starts in 35d
3    [ ]  #  consider making a cli table system                  Anytime
4    [ ]  #  take out the trash                                  Anytime
5    [ ]  o  Task sorting options                                Anytime

.- - - - - - - - - - - - - - - - ( another dir )- - - - - - - - - - - - - - - -.
a0   [-]  o  TitleTitleTitleTitleTitleTitleTitleTitleTitleTi...  16d remaining
a1   [ ]  .  test note                                           Due 16d ago
                            { another dir > deeper }
ad0  [ ]  .  consider making a cli table system                  Anytime
ad1  [-]  .  Task in deeper                                      Due 14d ago
ad2  [z]  .  waiting task                                        Starts in 35d
                           { .. > deeper > deepest }
add0 [z]  .  waiting task                                        Starts in 35d
                            { another dir > dongus }
ado0 [-]  .  Deengus Task!                                       Due 14d ago

.- - - - - - - - - - - - - - - -( subdirectory )- - - - - - - - - - - - - - - -.
s0   [z]  .  Another Task                                        Starts in 27d
s1   [x]  .  handle task creation with start in the future       Anytime
s2   [ ]  .  separate the YAML parsing for task files            Anytime
```
You can also add filters to focus on what's important.
```
~$ zdo -fd list +:home --sort priority

#     ?   !  Task
________________________________________________________________________________

4    [ ]  #  take out the trash                                  Anytime
ad1  [-]  .  Task in deeper                                      Due 14d ago
ado0 [-]  .  Deengus Task!                                       Due 14d ago
a1   [ ]  .  test note                                           Due 16d ago
```
And if you'd like to see a more detailed view of a given task, just use the `view` command. Lets revisit the expanded task file from earlier, which you might have noticed has index 1:
```
~$ zdo view 1
[x]  .  complete mark command
    Anytime
    Tags: {todo}
    Note:
        # complete mark command
        - [ ] Task index registry
            - [ ] Index specific to each `task` directory
        - [ ] Task selection via index registry

        ## Task Index:
        The index should assign a unique id number to a filepath.
        If a file is removed, the index number should be freed and available for
        reassignment.
        Indices should NEVER be shuffled: the same path should retain the same
        index^[0].
        Each `task` directory should retain its own index registry.
        Combining registries will prefix the id, e.g. `2 -> a2`.
        Global tasks have a reserved prefix: `_2`.


        [0] Within a relative index registry
```