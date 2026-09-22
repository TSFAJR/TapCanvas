package fullblast

import (
	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/stretchr/testify/require"
	"testing"
)

func TestFullBlastCanonicalVideoPayload(t *testing.T) {
	p, req, err := normalize([]byte(`{"model":"wan3.0-video","prompt":"A calm sea","duration":2,"size":"16:9","resolution":"720p","seed":0,"images":["https://example.com/input.png"],"metadata":{"vendor":"new_api","taskKind":"image_to_video"}}`))
	require.NoError(t, err)
	require.Equal(t, "2", req.Seconds)
	body, err := common.Marshal(p)
	require.NoError(t, err)
	require.JSONEq(t, `{"model":"wan3.0-video","prompt":"A calm sea","duration":2,"size":"720p","metadata":{"ratio":"16:9","seed":0,"media":[{"type":"reference_image","url":"https://example.com/input.png"}]}}`, string(body))
}

func TestFullBlastRejectsUnsupportedInputsBeforePayment(t *testing.T) {
	for _, body := range []string{
		`{"model":"wan3.0-video","prompt":"x","duration":1,"resolution":"720p"}`,
		`{"model":"wan3.0-video","prompt":"x","duration":2,"seconds":"5","resolution":"720p"}`,
		`{"model":"wan3.0-video","prompt":"x","duration":2,"resolution":"4k"}`,
		`{"model":"wan3.0-video","prompt":"x","duration":2,"resolution":"720p","images":["https://example.com/a.png","https://example.com/b.png"]}`,
		`{"model":"wan3.0-video","prompt":"x","duration":2,"resolution":"720p","metadata":{"video_url":"https://example.com/a.mp4"}}`,
	} {
		_, _, err := normalize([]byte(body))
		require.Error(t, err, body)
	}
}

func TestFullBlastResultAndFailure(t *testing.T) {
	a := &TaskAdaptor{}
	r, err := a.ParseTaskResult([]byte(`{"id":"upstream","status":"completed","metadata":{"url":"https://example.com/out.mp4"},"usage":{"output_video_seconds":2,"resolution":"720P"}}`))
	require.NoError(t, err)
	require.Equal(t, model.TaskStatusSuccess, r.Status)
	require.Equal(t, "https://example.com/out.mp4", r.Url)
	require.Equal(t, 2, r.OutputSeconds)
	require.Equal(t, "720p", r.Resolution)
	r, err = a.ParseTaskResult([]byte(`{"id":"upstream","status":"failed","error":{"message":"provider rejected input"}}`))
	require.NoError(t, err)
	require.Equal(t, model.TaskStatusFailure, r.Status)
	require.Equal(t, "provider rejected input", r.Reason)
	_, err = a.ParseTaskResult([]byte(`{"status":"completed"}`))
	require.Error(t, err)
	_, err = a.ParseTaskResult([]byte(`{"status":"unexpected"}`))
	require.Error(t, err)
}
