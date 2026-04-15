# Define 
System Prompt: 
- role
- tech stack

(Library) Goverance and Restrictions:
- Domain, Summary and Scope
- Goals (enablement)
- Restrictions (out of scope, restricted, monitored)

(Library) Best Practices for Tech stack:
- coding standards
- library standards: current, commonly used, no drama/conflicts, no blocking defects
  * prefer those with an automated security vefification and supply-chain verification
- If using a smaller and/or older LLM model, inject missing components

(Workflow) Company/Team policies: 
- adhere to: SOLID, DRY, GRASP
- adhere to and/or make use of where and/or as appropriate:
  * Inversion of Control (IoC) – design principle where control flow and object creation are delegated to an external system (e.g., a framework or container), rather than handled directly by your code 
  * Dependency Injection (DI) – inject dependencies instead of creating them
  * Service Locator – centralized lookup for dependencies
  * Hollywood Principle – “Don’t call us, we’ll call you”
  * Framework vs Library – frameworks control flow (IoC), libraries don’t
  * Separation of Concerns (SoC) – split responsibilities
  * Loose Coupling – reduce interdependencies
  * High Cohesion – keep modules focused
  * Programming to Interfaces – depend on abstractions
  * Strategy Pattern – inject interchangeable behavior
  * Observer Pattern – react to events
  * Template Method Pattern – base class controls flow
  * Factory Pattern – delegate object creation
  * Event-Driven Architecture – flow driven by events
  * Plugin / Extension Architecture – pluggable components
  * Middleware Pipelines – framework-controlled processing chains
  * componentize - build (public, private, internal) components whenever possible:
    - SRP + DRY + Separation of Concerns → create small reusable units
    - CRP + CCP → organize them into meaningful components
    - IoC → keep them loosely coupled and composable
  * Composition Over Inheritance - Prefer composition over inheritance and keep hierarchies shallow:
    - Guidance: 
       - “Keep inheritance hierarchies shallow”
       - “Avoid deep inheritance trees”
       - “Flatten your hierarchy”
       - “Favor delegation”
   - Design Patterns:
       - Strategy Pattern → replace subclassing with interchangeable behavior
       - Decorator Pattern → extend behavior without inheritance explosion
       - Factory Pattern → avoid subclass-based construction logic
- test passing parameters/inputs at all interface boundaries
- overrides
  - all public fuctions have a full documentation block kept up to date on ever thcnage
  - all private/protected functions have at least a minimum doc, expanded for complication
  - all packages or directories should contain documentation suffient to justify its existance through a description
  - all LLM Agent created markdown documents will contain/lead with:
    1. Title: name or title of document
    2. Purpose: brief purpose of document
    3. Audiance: intended audiance
    4. Last Updated: last Updated date and time stamp
    5. Table of Contents: 3 levels of header outlines, hyperlinked
    6. <Header specified contents for that file's purpose>, prioritize and organized for top-down reading
    7. References: files, directory or URLs referenced in the content are important for a complete context of this doucment, prioritized to the content in this file
    8. Also see: list of other (markdown) documents to consider, often adjacent to this file 
  
(Personal) Personal guideance: 
- where possible, isolate the development and/or deployment environment (ie sandbox) from host operation system via standardized approachs
- testing per Step and then Phase before checkins: when in double check the build
- all determed defects have a numbered and named unit test for the expressed defect which passes when the defect is handled successfully
- must be compile before all checkings
- all tests must pass before checkins
- test coverage at or aboe 90% for significant units work works
- integratoin tests (end-to-end) with mockups for "golden path" required
- Automated directories, files creation and maintenace (IE listing in README-agent.md as required):
  - ./README.md - human readable, prioritzed around building and testing
  - ./README-agent.md - LLM Agent focused hyper linked index to important resource in this project necessary for the successful execution of any (ie general) assignmement
  - ./docs/changelog.md - date time stamp and commit hash terse summary of any and all changes to code 
  - ./docs/feature.md - date time stamp and commit hash existing and new feature list
  - ./docs/decions.md - date time stamp and commit hash of implementation decision impacting a given assignment, usually focused on feature or API expression
  - ./docs/lessons-learned-[tech|other].md -  date time stamp, Last updated and Table of Contents of new observations not contained with in the LLM Agent's model, provided (markdown) materials or overtly found in a web-RAG process. This may be software or hardware technology, component versions, ways of working All technology related items go in lessons-learned-tech.md and ways or work and/or other learning go int lessons-learned-other.md. 
  - ./docs/system-view.ms - contains a system archiectural-level diagram of components by domains, a  high-level call and response diagram for this solution/repo, an internal collaboration diagram for the entire solution, 
    * use mermain diagram technology
  - ./docs/wip/ - work in progress where the implementation plan (with status tracking) is managed 
  Note: all create LLM Agent creatd outside of these are to be placed in ./docs/other/
- enable an local, LLM Agent based "MCP Tooling" in ./tools/ for automatic availability:
   1. work around Copilot's "write new file" defect: 
      - create python "write to new file" to work around built-in defect
 
(Meta) Pair-Programming Personality:
- how the developer wants an LLM Agent to communicate with the developer
  * usually a .gitignore as this is personality-focused PII for devs
- personal guidance:
  1. three levels: programer (passive), engineer (refines), solutions analysist (alternative ideas and pushback)
  2. examine, take ownership and migrated lessons-learned-other.md which are related to LLM-Agent to Human interaction.


(Workflow) Assignment Workflow: 
- automated files initalized and scheduled
- assessment and refinement
- prioritized planning
- git commits schedule and commit messages
- change logs and planning status updates

(Workflow) # Construction


(Workflow) # Scheduling and Excution
- 

- Completed Assignment Verification

(Workflow|Library|Personal|Meta) # Closing, Publication and Summary Updates





