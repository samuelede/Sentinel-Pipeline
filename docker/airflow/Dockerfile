FROM apache/airflow:2.9.1-python3.11

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl gnupg unzip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

USER airflow

# Install snowsql AS the airflow user (not root), so its binary payload
# lands under /home/airflow/.snowsql, the airflow user's home directory,
# matching where it looks for that payload at runtime. Installing this
# as root would put the payload under /root/.snowsql instead, which the
# airflow user can never see regardless of volume mounts, that's what
# caused "SnowSQL was not found in /home/airflow/.snowsql" even after
# the binary was successfully installed during the build. SNOWSQL_DEST
# uses /home/airflow/.local/bin since that's already on PATH for every
# shell type in this base image (baked into the image's ENV, unlike
# .bashrc/.profile, which BashOperator's non-interactive subprocess
# never sources). Version matches what's used on the host (confirmed
# via `snowsql -v` -> 1.5.1) to avoid version drift between native and
# containerized runs.
RUN curl -O https://sfc-repo.snowflakecomputing.com/snowsql/bootstrap/1.5/linux_x86_64/snowsql-1.5.1-linux_x86_64.bash && \
    SNOWSQL_DEST=/home/airflow/.local/bin SNOWSQL_LOGIN_SHELL=/home/airflow/.bashrc bash snowsql-1.5.1-linux_x86_64.bash && \
    rm snowsql-1.5.1-linux_x86_64.bash

# Install this project's own dependencies (extractors, validators, transformers
# need boto3, pandas, psycopg2, great_expectations, etc.) on top of Airflow's
# own requirements. apache-airflow itself is already satisfied by the base
# image, pip will just confirm it and move on.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
