FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["gunicorn", "--preload", "-k", "gevent", "-b", "0.0.0.0:4900", "app:app"]
