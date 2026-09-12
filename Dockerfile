FROM python:3.12-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

# Microsoft ODBC Driver 18 + sqlcmd (mssql-tools18), needed for pyodbc
# (agent DB access) and for the in-cluster DB init job.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gnupg2 ca-certificates unixodbc-dev gcc g++ \
    && curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
    && curl -sSL -o /etc/apt/sources.list.d/mssql-release.list https://packages.microsoft.com/config/debian/12/prod.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 mssql-tools18 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV PATH="$PATH:/opt/mssql-tools18/bin"

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ src/
COPY scripts/ scripts/
COPY data/policy/ data/policy/
COPY data/raw/ data/raw/
COPY data/source/ data/source/
COPY chainlit.md .

EXPOSE 8000

CMD ["chainlit", "run", "src/ui_chainlit.py", "--headless", "--host", "0.0.0.0", "--port", "8000"]
