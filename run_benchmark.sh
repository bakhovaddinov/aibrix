bash benchmark.sh \
  --model Qwen-2.5-7B-Instruct \
  --input-start 256 \
  --input-limit 1024 \
  --output-start 256 \
  --output-limit 1024 \
  --rate-start 1 \
  --rate-limit 4 \
  -o ./result/qwen257_npu_fast.jsonl
