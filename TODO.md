# Development Notes

- filesplitter
  - Claude code has a file token limit of 25,000 before it requires the use of limit and offset parameters to read portions of the file. It also has a max file size limit of 500k, and will not even attempt to open the file if it exceed that.
  - Created a tokencount python script that uses tiktoken to give an accurate token estimation for any input.
  - filesplitter script will attempt to break down files over 25,000 tokens into smaller chunks

- Draft workflow inspired by other projects
  - PRD generation based upon https://github.com/JeredBlu/custom-instructions
    - However this may only be useful for green field work
  - PRD to task conversation based upon https://github.com/eyaltoledano/claude-task-master
  - Task generation to GitHub Issue conversation (In Progress)
  - GitHub Issue to Code based upon RIPER (https://github.com/johnpeterman72/CursorRIPER.sigma)
    - Cursor to Claude conversion required
    - GitHub CLI context required
      - Already exists, just need to migrate
        - Issue as source of truth, status tracking via Project, PR management, comments as documentation
    - Context7 for API Context (https://github.com/upstash/context7)
    - Basic Memory for knowledge management (https://github.com/basicmachines-co/basic-memory)
    - Sequential Thinking for complex work (https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking)
  - PR Validation (In Progress)
    - https://www.coderabbit.ai/ or custom?

- Ideas that need incorporation
  - Focus on TDD to avoid hallucinations
  - PR Validation needs review workflow
    - Architecture Review
    - Acceptance Criteria Review
    - Testing Review
    - Documentation Review
  - Micromanager Concept
    - Second agent that constantly keeps an eye on activity? Corrective feedback provided by GitHub comments?
    - Gemini million token based? Provide zip of main branch with diff of feature branch along with AC/Architecture for review?
      - Two zip files has confused it before, so one zip as before and a diff for after will likely work better.