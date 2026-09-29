FROM python:3.11-slim
WORKDIR /app
RUN pip install boto3
COPY canary.py .
CMD ["python", "canary.py"]