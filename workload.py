print("Executing dynamic workload from S3...")
# Simulate some data processing and write an output file
with open("/workspace/output.txt", "w") as f:
    f.write("Diagnostic complete. No anomalies detected in execution state.")
print("Results written to output.txt successfully.")