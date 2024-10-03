# TODO Application
The idea is to have a server-based application to sync tasks.

I'm visualizing each task like a card with a mainline and an optional description line.
I think each of these cards should literally be just a file with the first line being the description, the following line being datetime stuff, and the last line being the optional description in markdown format (or honestly whatever format).

The server should accept authorized connections to store a new task, write that task to a file on the host system, and then synchronize to whatever other systems happen to be subscribing. 

It would also be nice to have some convenient tools for creating tasks and seeing what is coming up.
The best starting point is definitely command line tools.
```
task new Get groceries for the week :by tomorrow:
```
```
task view :by this week: p>
```
```
task search [work] p<
```
```
task new Make a vet appointement :by friday: ?
$> Call our regular vet for some bloodwork within the next 2 weeks or so
```

This sort of ux will require not only the baseline file manipulation system, but also a way to convert between natural language text and date-times. 
I should also determine what the best way to handle recurring tasks is, and how to delete tasks in a way that provides the greatest control.


## Obsidian Integration
If I define the cards to use a format consistent with obsidian's task systems, I could probably optionally configure the file storage location to be inside an obsidian vault and integrate directly with the existing tasks.
I do think this may be anithetical to the idea of a dedicated, simplified task system, but it could be neat to have the option to integrate. 


## Updated API Thoughts
Trying to be more terse in how I interact with the application.
Trying to keep interactions in the cli and not in an interactive loop.

Example idea for creating a new task:
```
zdo new +project +work --due cob --priority 5 Send the project email
```
Would be a task called "Send the project email" with tags [project, work] a due date at the close of business, and a priority of 5.
shorthand: `zdo -n +project,work -d cob -p 5 Send the project email`

There also needs to be a nice interface to update/complete tasks.
I'm trying to keep everything to an 80 character line length for wider adoption.
```
$> zdo list -l
#  | Task
--------------------------------------------------------------------------------
1.  [ ] TitleTitleTitleTitleTitleTitleTitleTitleTitleTitleTitleTitleTitleTitle...
<5> 16 days (2024-5-10 -> 2024-6-20)
    Tags: {tagA, tagB, tagC}

    Note:
    Description of the task goes here. Lorem ipsum dolor sit amet, consectetur
    adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna
    aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris...

2.  [ ] Short title
<3> 14 days (2024-6-18)
    Tags: {tagA, tagB, tagC}

3.  [ ] Another task to do
<7> 90 days (2024-8-1 -> 2024-9-1)
    Tags: {tagA, tagB, tagC}

    Note:
    Description of the task goes here. Lorem ipsum dolor sit amet, consectetur
```

or short form
```
$> zdo list
# | Task
--------------------------------------------------------------------------------
1. [ ] <5> TitleTitleTitleTitleTitleTitleT... | 16 days (2024-5-10 -> 2024-6-20)
2. [ ] <3> Short title                        | 14 days (2024-6-18)
3. [ ] <7> Another task to do                 | 90 days (2024-8-1 -> 2024-9-1)
```

To mark something done:
```
$> zdo mark 2 done
# | Task
--------------------------------------------------------------------------------
1. [ ] <5> TitleTitleTitleTitleTitleTitleT... | 16 days (2024-5-10 -> 2024-6-20)
2. [X] <3> Short title                        | 14 days (2024-6-18)
3. [ ] <7> Another task to do                 | 90 days (2024-8-1 -> 2024-9-1)
```
or another status
```
$> zdo mark 3 waiting
# | Task
--------------------------------------------------------------------------------
1. [ ] <5> TitleTitleTitleTitleTitleTitleT... | 16 days (2024-5-10 -> 2024-6-20)
2. [X] <3> Short title                        | 14 days (2024-6-18)
3. [z] <7> Another task to do                 | 90 days (2024-8-1 -> 2024-9-1)
```

shorthand: `zdo -m 3w`

Take inspiration from taskwarrior for a lot of this API. 
Filtering for example should be very similar:
```
zdo +project list
```
should only list tasks tagged with "project"

## Task Registry
> NEVER MIND! I HAVE DECIDED TO SORT THEM TEMPORALY HOWEVER, I DO STILL WANT THE NESTED INDEXING THING
There's no good way to reference tasks without either assigning each of them an id or by making an interactive cli tool.
Beacuse I specifically want to keep this tool pipeable, I have to ignore the last option. 
I also really don't want to pollute the task file front-matter with an id.

I think each task directory should have a special file that acts like a local task registry.
Within that registry, we store an integer id and a file path relative to the parent task directory.
These ids only need to be unique within the task directory and can be recycled if tasks are removed.
The registry is just a csv file, so there's room to add additional metadata in the future (or through plugins)

Example:
```
id,path
1,../rel/path/to/task.md
2,../../another/path/again.md
3,./task.md
9,./out/of/order/is/fine.md
6,./another task.md
```

When there are nested task directories, their registries are combined at runtime and each task id will accept a prefix.
Global tasks will all begin with a special prefix, denoting their externality.
Nested directory prefixes will stack in hierarchical order. 
For example, assume a directory structure like this (alongside a given global task directory):
```
~/project/
    |-- src/
    |   `-- ...
    |-- docs/
    |   `-- ...
    `-- .tasks/
        |-- tasks.zdo
        |-- major task.md
        |-- another long name task.md
        |-- issues/
        |   |-- tasks.zdo
        |   |-- fix #89123.md
        |   `-- impl feat-button.md
        `-- others/
            `-- random task.md
            `-- deep/
                `-- deep task.md

~/.tasks
    |-- tasks.zdo
    |-- post my resume online.md
    |-- draft exit email.md
    `-- home/
        |-- tasks.zdo
        |-- buy milk.md
        `-- buy eggs.md
```

Running `zdo list` from `~/project` should assign ids like:
```
id      Task
----------------------------------
1       major task
2       another long name task
a1      fix #89123
a2      impl feat-button
b1      random task
ba1     deep task
_1      post my resume online
_2      draft exit email
_a1     buy milk
_a2     buy eggs
```

We might even provide preference to prefix with the first letter of the subdirectory:
```
id      Task
----------------------------------
1       major task
2       another long name task
i1      fix #89123
i2      impl feat-button
o1      random task
od1     deep task
_1      post my resume online
_2      draft exit email
_h1     buy milk
_h2     buy eggs
```

Now, we can add all sorts of optimizations and conveniences here. 
For example, if all of the github issue related tasks are tagged `issue`, we can list them with: `zdo list +issue`.
If all of the tasks are on or below the same hierarchical level, we can make that level the base level. 
Take the lowest level of any task, then make that level the root. 
Example: 
```
$~/project> zdo list +issue
id      Task
----------------------------------
1       fix #89123
2       impl feat-button
```

Suddenly, marking becomes easy to implement by simply selecting a task via the runtime hashmap indexed by id:
- `zdo mark i2`
- `zdo mark od1 active`
- `zdo +issue mark 1`

I also want each task to have the same id when queried from the same location. 
That means, when applying filters, they would be applied *after* we assign the ids from our registry system.

## Open Command
This is where we're *probably* going to need to introduce OS specific routines.
I would like to be able to open a task by id using `zdo open $ID`; however, that means we need to ask the system to open the file in a default editor.
The process of selecting and calling the default editor is different for each system. 
### Windows
This might be as simple as `ShellExecute`, but will require linking `shellapi.h` when building for windows targets.
### Linux
Maybe a bit more difficult than windows because of all the possible environments we could be running in.
The generally accepted "best" approach is to iteratively try to find things in the path/environment[0], e.g.:
1. `xdg-open`
2. `/usr/bin/sensible-editor`
3. `$EDITOR`
4. `$VISUAL`
5. `$SELECTED_EDITOR`
6. `vim`
7. `vi`
8. `emacs`
9. `nano`

[0] [stackoverflow answer](https://stackoverflow.com/a/21045598/8286052)



## Design

```
$~/project> zdo list

#    ?   P  Task
================================================================================
3   [/] <5> TitleTitleTitleTitleTitleTitleTitleTitleTi... | Due in 29 days
2   [z] <3> Another Task                                  | Due in 72 days
4   [/] <3> This is an example task                       | Due 1 day ago
0   [ ] <0> complete mark command                         | Anytime
1   [ ] <0> consider making a cli table system            | Anytime

----------------------- Subdir ------------------------------------------------
s0  [ ] <5> handle task creation with start in the future | Anytime
s2  [ ] <4> separate the YAML parsing for task files      | Anytime
s1  [ ] <0> test note                                     | Due 3 day ago
s3  [z] <0> waiting task                                  | Starts in 48 days
-- Subdir > Random ---------------------------------------
sr2 [ ] <3> handle task creation with start in the future | Anytime
sr0 [ ] <0> separate the YAML parsing for task files      | Anytime
sr1 [ ] <0> test note                                     | Due 3 day ago

------------------------ Anotherdir --------------------------------------------
a0  [ ] <5> handle task creation with start in the future | Anytime
a2  [ ] <4> separate the YAML parsing for task files      | Anytime
a1  [ ] <0> test note                                     | Due 3 day ago
-- Anotherdir > Sub --------------------------------------
as2 [ ] <3> handle task creation with start in the future | Anytime
as0 [ ] <0> separate the YAML parsing for task files      | Anytime
as1 [ ] <0> test note                                     | Due 3 day ago
as3 [z] <0> waiting task                                  | Starts in 48 days


=================================== GLOBAL ======================================
_2  [/] <5> TitleTitleTitleTitleTitleTitleTitleTitleTi... | Due in 29 days
_0  [ ] <0> complete mark command                         | Anytime
_1  [ ] <0> consider making a cli table system            | Anytime

```

```
$~/project> zdo list

 .============================| MY PROJECT |==================================.
'                                                                              '
  #    ?   P                       Task
  ````````````````````````````````````````````````````````````````````````````
  3   [/] <5>  TitleTitleTitleTitleTitleTitleTitleTitleTi...   Due in 29 days
  2   [z] <3>  Another Task                                    Due in 72 days
  4   [/] <3>  This is an example task                         Due 1 days ago
  0   [ ] <0>  complete mark command                           Anytime
  1   [ ] <0>  consider making a cli table system              Anytime
.                                                                              .
|:- - - - - - - - - - - - - - - -( Subdir )- - - - - - - - - - - - - - - - - -:|
| s0  [ ] <5>  handle task creation with start in the future   Anytime         |
' s2  [ ] <4>  separate the YAML parsing for task files        Anytime         '
  s1  [ ] <0>  test note                                       Due 3 days ago
  s3  [z] <0>  waiting task                                    Starts in 48d
                              Subdir > Random 
  sr2 [ ] <3>  handle task creation with start in the future   Anytime
  sr0 [ ] <0>  separate the YAML parsing for task files        Anytime
  sr1 [ ] <0>  test note                                       Due 3 days ago
.                                                                              .
|:- - - - - - - - - - - - - - -( Anotherdir )- - - - - - - - - - - - - - - - -:|
| a0  [ ] <5>  handle task creation with start in the future   Anytime         |
' a2  [ ] <4>  separate the YAML parsing for task files        Anytime         '
  a1  [ ] <0>  test note                                       Due 3 days ago
                             Anotherdir > Sub
  as2 [ ] <3>  handle task creation with start in the future   Anytime
  as0 [ ] <0>  separate the YAML parsing for task files        Anytime
  as1 [ ] <0>  test note                                       Due 3 days ago
  as3 [z] <0>  waiting task                                    Starts in 48d


 .-------------------------------| GLOBAL |-----------------------------------.
  _2  [/] <5>  TitleTitleTitleTitleTitleTitleTitleTitleTi...   Due in 29 days
  _0  [ ] <0>  complete mark command                           Anytime
  _1  [ ] <0>  consider making a cli table system              Anytime

```

```
$~/project> zdo list

#    ?   P                         Task
________________________________________________________________________________

3   [/] <5>  TitleTitleTitleTitleTitleTitleTitleTitleTi...   Due in 29 days
2   [z] <3>  Another Task                                    Due in 72 days
4   [/] <3>  This is an example task                         Due 1 days ago
0   [ ] <0>  complete mark command                           Anytime
1   [ ] <0>  consider making a cli table system              Anytime

- - - - - - - - - - - - - - - - -( Subdir )- - - - - - - - - - - - - - - - - - -
s0  [ ] <5>  handle task creation with start in the future   Anytime         
s2  [ ] <4>  separate the YAML parsing for task files        Anytime         
s1  [ ] <0>  test note                                       Due 3 days ago
s3  [z] <0>  waiting task                                    Starts in 48d
                              Subdir > Random 
sr2 [ ] <3>  handle task creation with start in the future   Anytime
sr0 [ ] <0>  separate the YAML parsing for task files        Anytime
sr1 [ ] <0>  test note                                       Due 3 days ago

- - - - - - - - - - - - - - - -( Anotherdir )- - - - - - - - - - - - - - - - - -
a0  [ ] <5>  handle task creation with start in the future   Anytime         
a2  [ ] <4>  separate the YAML parsing for task files        Anytime         
a1  [ ] <0>  test note                                       Due 3 days ago
                              Anotherdir > Sub
as2 [ ] <3>  handle task creation with start in the future   Anytime
as0 [ ] <0>  separate the YAML parsing for task files        Anytime
as1 [ ] <0>  test note                                       Due 3 days ago
as3 [z] <0>  waiting task                                    Starts in 48d


---------------------------------- GLOBAL --------------------------------------
_2  [/] <5>  TitleTitleTitleTitleTitleTitleTitleTitleTi...   Due in 29 days
_0  [ ] <0>  complete mark command                           Anytime
_1  [ ] <0>  consider making a cli table system              Anytime

```


```
$~/project> zdo list

#     ?   P                         Task
________________________________________________________________________________

3    [x]  #  TitleTitleTitleTitleTitleTitleTitleTitleTitleTi...   Done!
2    [z]  #  Another Task                                         Due in 72d
4    [-]  o  This is an example task                              Due 1d ago
0    [ ]  .  complete mark command                                Anytime
1    [ ]  .  consider making a cli table system                   Anytime

.- - - - - - - - - - - - - - - - -( Subdir )- - - - - - - - - - - - - - - - - -.
s0   [ ]  #  handle task creation with start in the future        Anytime         
s2   [ ]  o  separate the YAML parsing for task files             Anytime         
s1   [ ]  .  test note                                            Due 3d ago
s3   [z]  .  waiting task                                         Starts in 48d
                             { Subdir > Random }
sr2  [ ]  #  handle task creation with start in the future        Anytime
sr0  [ ]  .  separate the YAML parsing for task files             Anytime
sr1  [ ]  .  test note                                            Due 3d ago

.- - - - - - - - - - - - - - - -( Anotherdir )- - - - - - - - - - - - - - - - -.
a0   [ ]  #  handle task creation with start in the future        Anytime         
a2   [ ]  .  separate the YAML parsing for task files             Anytime         
a1   [ ]  .  test note                                            Due 3d ago
                            { Anotherdir > Sub }
as2  [ ]  o  handle task creation with start in the future        Anytime
as0  [ ]  .  separate the YAML parsing for task files             Anytime
as1  [ ]  .  test note                                            Due 3d ago
as3  [z]  .  this is a long task name for testing layout          Starts in 48d
                         { Anotherdir > Sub > Deep }
asd2 [ ]  o  handle task creation with start in the future        Anytime
asd0 [ ]  .  separate the YAML parsing for task files             Anytime
asd1 [ ]  .  test note                                            Due 3d ago
asd3 [z]  .  waiting task                                         Starts in 48d
                         { ... > Deep > Super Deep}
.ds2 [ ]  o  handle task creation with start in the future        Anytime
.ds0 [ ]  .  separate the YAML parsing for task files             Anytime
.ds1 [ ]  .  test note                                            Due 3d ago
.ds3 [z]  .  waiting task                                         Starts in 48d
                         { ... > Deep > Sooperdeep}
.do2 [ ]  o  handle task creation with start in the future        Anytime
.do0 [ ]  .  separate the YAML parsing for task files             Anytime
.do1 [ ]  .  test note                                            Due 3d ago
.do3 [z]  .  waiting task                                         Starts in 48d


----------------------------------- GLOBAL -------------------------------------
_2   [-]  o  TitleTitleTitleTitleTitleTitleTitleTitleTi...        Due in 29d
_0   [ ]  .  complete mark command                                Anytime
_1   [ ]  .  consider making a cli table system                   Anytime

```

## Handling "Natural Language" Dates
It would be exceptionally convenient if the application could accept something more natural for the due date position of a task.
Right now (Oct 2, 2024) the only accepted date format is YYYY-MM-DD, which isn't very ergonomic.
In the majority of cases, you really don't even *want* to specify the year since the task is due within a few days or weeks.
The time locality of task planning means that most of the datestring is redundant...

I think a reasonable place to start is with some simple numeric offsets.
For example:
- `1 week` would be $TODAY + 7 days
- `5 days` would be $TODAY + 5 days
- `one month` would be $TODAY + 30 days
- `2 years` would be $TODAY + 365 days (+1 for leap years)

A natural extension would be prepositional offsets.
For example:
- `next Tuesday`
- `next Month` (ambiguous if +30 days or 1st of the month)
- `2 weeks from Thursday`
- `1 week after &id` where id is a task id
- `tuesday after next`
- `friday after &id`
