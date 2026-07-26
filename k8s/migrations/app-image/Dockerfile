# Client-shaped migration fixture: an "application image" whose migrations run through its
# own scripts (config/db_setup.sh, or config/db_snapshot.sh when SNAPSHOT_JOB=true), the way
# a Rails image runs `bundle exec rake db:migrate` via a setup script.
# mysql:8.0 base gives us sh + the mysql client standing in for the app's migration tool.
# Build + load with: task migrations:app:image:build
FROM mysql:8.0
WORKDIR /home/app
COPY --chmod=755 config/ config/
COPY db/ db/
