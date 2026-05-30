# git checkout release
# see if there's a .suede folder, if so:
# - `git mv` (& commit) it temporarily to avoid conflicts with the new one
# see if there's a .github/worflows folder, if so:
# - If there is a file 'subrepo-pull-into-main.yml' delete it
# - then, if .github/worflows is empty, delete the folder.
# - else if there are other files, `git mv` (& commit) the .github/workflows folder temporarily to avoid conflicts with the new one
# then run:
# - mkdir -p .github 
# - git subrepo clone https://github.com/pmalacho-mit/suede.git .github/workflows --branch=workflows/dependency/release
# - git subrepo clone https://github.com/pmalacho-mit/suede.git .suede --branch=templates/dependency/release_.suede

