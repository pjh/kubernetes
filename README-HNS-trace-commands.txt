gcloud compute ssh e2e-test-peterhornyack-windows-node-group-lkqs --zone us-central1-b --command "netsh trace start globallevel=6 provider={564368D6-577B-4af5-AD84-1C54464848E6} provider={0c885e0d-6eb6-476c-a048-2457eed3a5c1} provider={80CE50DE-D264-4581-950D-ABADEEE0D340} provider={D0E4BC17-34C7-43fc-9A72-D89A59D6979A} provider={93f693dc-9163-4dee-af64-d855218af242} provider={A6F32731-9A38-4159-A220-3D9B7FC5FE5D} report=di capture=no tracefile=c:\server.etl overwrite=yes persistent=yes"; \
gcloud compute ssh e2e-test-peterhornyack-windows-node-group-rqkw --zone us-central1-b --command "netsh trace start globallevel=6 provider={564368D6-577B-4af5-AD84-1C54464848E6} provider={0c885e0d-6eb6-476c-a048-2457eed3a5c1} provider={80CE50DE-D264-4581-950D-ABADEEE0D340} provider={D0E4BC17-34C7-43fc-9A72-D89A59D6979A} provider={93f693dc-9163-4dee-af64-d855218af242} provider={A6F32731-9A38-4159-A220-3D9B7FC5FE5D} report=di capture=no tracefile=c:\server.etl overwrite=yes persistent=yes"; \
sleep 20; \
./run-e2e.sh --node-os-distro=windows \
  --ginkgo.focus="\[Conformance\]|\[NodeConformance\]|\[sig-windows\]" \
  --ginkgo.skip="\[LinuxOnly\]|\[Serial\]|\[Feature:.+\]" --minStartupPods=8; \
gcloud compute ssh e2e-test-peterhornyack-windows-node-group-lkqs --zone us-central1-b --command "netsh trace stop"; \
gcloud compute ssh e2e-test-peterhornyack-windows-node-group-rqkw --zone us-central1-b --command "netsh trace stop"
	# TODO next time: redirect output :)

gcloud compute scp e2e-test-peterhornyack-windows-node-group-lkqs:C:\\server.etl lkqs-server.etl --zone us-central1-b
gcloud compute scp e2e-test-peterhornyack-windows-node-group-rqkw:C:\\server.etl rqkw-server.etl --zone us-central1-b
