# Image-native Flyway migrations demo: the SQL is baked into the job image, mirrord runs it
# with `locations: ["filesystem:/flyway/sql-baked"]` - no upload from the runner.
# Build + load with: task migrations:image:build
FROM flyway/flyway:12
COPY sql /flyway/sql-baked
