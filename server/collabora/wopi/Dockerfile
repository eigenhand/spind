FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin wopi
USER wopi

EXPOSE 9981
# --no-access-log: die Request-URLs enthalten die Zugriffs-Token, und ein
# Token IST der Schlüssel zur Datei. Fehler protokolliert der Dienst selbst.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "9981", \
     "--proxy-headers", "--no-access-log"]
