##### STAGE 0
FROM node:14 as frontend

# Make build & post-install scripts behave as if we were in a CI environment (e.g. for logging verbosity purposes).
ARG CI=true

# Install front-end dependencies.
COPY package.json package-lock.json .babelrc.js webpack.config.js ./
RUN npm ci --no-optional --no-audit --progress=false

# Compile static files
COPY ./learning_equality/static_src/ ./learning_equality/static_src/
RUN npm run build:prod

##### STAGE 1
# Going with slim-buster, even though that means installing a compiler
FROM python:3.8-slim-buster as backend
RUN apt update && \
    apt install -y wget libpq-dev gcc libjpeg62-turbo-dev && \
    rm -rf /var/cache/apt

RUN useradd learning_equality -m && \
    mkdir /app && chown learning_equality: /app

WORKDIR /app

# Set default environment variables. They are used at build time and runtime.
# If you specify your own environment variables elsewhere, they will
# override the ones set here. The ones below serve as sane defaults only.
#  * PATH - Make sure that Poetry is on the PATH
#  * PYTHONUNBUFFERED - This is useful so Python does not hold any messages
#    from being output.
#    https://docs.python.org/3.8/using/cmdline.html#envvar-PYTHONUNBUFFERED
#    https://docs.python.org/3.8/using/cmdline.html#cmdoption-u
#  * PYTHONPATH - enables use of django-admin command.
#  * DJANGO_SETTINGS_MODULE - default settings used in the container.
#  * PORT - PORT variable is
#    read/used by Gunicorn.
#  * WEB_CONCURRENCY - number of workers used by Gunicorn. The variable is
#    read by Gunicorn.
#  * GUNICORN_CMD_ARGS - additional arguments to be passed to Gunicorn. This
#    variable is read by Gunicorn
# TODO we're setting a production module (hardcoded) but reading $BUILD_ENV
ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app \
    DJANGO_SETTINGS_MODULE=learning_equality.settings.production \
    PORT=8000 \
    WEB_CONCURRENCY=3 \
    GUNICORN_CMD_ARGS="-c gunicorn-conf.py --max-requests 1200 --max-requests-jitter 50 --access-logfile - --timeout 25"

ARG BUILD_ENV

# Make $BUILD_ENV available at runtime
ENV BUILD_ENV=${BUILD_ENV}

# Port exposed by this container. Should default to the port used by your WSGI
# server (Gunicorn).
#TODO a good candidate for config
EXPOSE 8000

# Install poetry using the installer (keeps Poetry's dependencies isolated from the app's)
ARG POETRY_HOME=/opt/poetry
ENV PATH=$PATH:${POETRY_HOME}/bin
ADD --chown=learning_equality https://raw.githubusercontent.com/python-poetry/poetry/1.1.5/get-poetry.py /app/
RUN echo "eedf0fe5a31e5bb899efa581cbe4df59af02ea5f get-poetry.py" | sha1sum -c - && \
    python get-poetry.py && \
    rm get-poetry.py && \
    poetry config virtualenvs.create false

# Install your app's Python requirements.
# TODO:
#   1. eliminate conditional logic with targets
#   2. do this in a venv and then copy the environment over to a third stage
COPY --chown=learning_equality pyproject.toml poetry.lock ./
COPY --chown=learning_equality --from=frontend ./learning_equality/static_compiled ./learning_equality/static_compiled

# Copy application code.
COPY --chown=learning_equality . .

# Collect static. This command will move static files from application
# directories and "static_compiled" folder to the main static directory that
# will be served by the WSGI server.
#TODO: can we remove this as a result of whitenoise?
RUN SECRET_KEY=none python manage.py collectstatic --noinput --clear

# Load shortcuts
COPY --chown=learning_equality ./docker/bashrc.sh /home/learning_equality/.bashrc

##### STAGE 2
FROM builder as dev
RUN poetry install --extras gunicorn
# Don't use the root user as it's an anti-pattern
USER learning_equality
# Run the WSGI server. It reads GUNICORN_CMD_ARGS, PORT and WEB_CONCURRENCY
# environment variable hence we don't specify a lot options below.
CMD gunicorn learning_equality.wsgi:application

##### STAGE 3
FROM dev as staging
USER learning_equality
CMD gunicorn learning_equality.wsgi:application

##### STAGE 4
FROM builder as prod
RUN poetry install --no-dev --extras gunicorn
USER learning_equality
CMD gunicorn learning_equality.wsgi:application
