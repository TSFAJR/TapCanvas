package fullblast

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/constant"
	"github.com/QuantumNous/new-api/dto"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/relay/channel/task/sora"
	relaycommon "github.com/QuantumNous/new-api/relay/common"
	"github.com/QuantumNous/new-api/service"
	"github.com/gin-gonic/gin"
)

// FullBlast has OpenAI task identities but a distinct JSON media/result contract.
type TaskAdaptor struct{ sora.TaskAdaptor }

type media struct {
	Type string `json:"type"`
	URL  string `json:"url"`
}
type metadata struct {
	Ratio string  `json:"ratio"`
	Media []media `json:"media,omitempty"`
	Seed  *int    `json:"seed,omitempty"`
}
type payload struct {
	Model    string   `json:"model"`
	Prompt   string   `json:"prompt"`
	Duration int      `json:"duration"`
	Size     string   `json:"size"`
	Metadata metadata `json:"metadata"`
}

func normalize(body []byte) (payload, relaycommon.TaskSubmitReq, error) {
	var req relaycommon.TaskSubmitReq
	var out payload
	fail := func(message string) (payload, relaycommon.TaskSubmitReq, error) {
		return out, req, fmt.Errorf("%s", message)
	}
	if err := common.Unmarshal(body, &req); err != nil {
		return out, req, err
	}
	if req.Model != "wan3.0-video" {
		return fail("FullBlast route supports wan3.0-video only")
	}
	if strings.TrimSpace(req.Prompt) == "" {
		return fail("prompt is required")
	}
	duration := req.Duration
	if req.Seconds != "" {
		n, err := strconv.Atoi(req.Seconds)
		if err != nil || (duration != 0 && duration != n) {
			return fail("seconds and duration must be consistent integers")
		}
		duration = n
	}
	if duration < 2 || duration > 30 {
		return fail("duration must be between 2 and 30 seconds")
	}
	resolution := strings.ToLower(strings.TrimSpace(req.Resolution))
	if resolution == "" {
		resolution = strings.ToLower(req.Size)
	}
	if resolution != "480p" && resolution != "720p" && resolution != "1080p" {
		return fail("resolution must be 480p, 720p or 1080p")
	}
	ratio := req.AspectRatio
	if ratio == "" && strings.Contains(req.Size, ":") {
		ratio = req.Size
	}
	if ratio == "" {
		ratio = "16:9"
	}
	if ratio != "16:9" && ratio != "9:16" && ratio != "1:1" {
		return fail("supported aspect ratios are 16:9, 9:16 and 1:1")
	}
	if len(req.ReferenceVideos)+len(req.ReferenceAudios)+len(req.Audios)+len(req.VideoReferences) > 0 || req.EndFrame != "" {
		return fail("this deployment supports text or a single reference image, not video/audio/end-frame inputs")
	}
	refs := append(append(append([]string{}, req.Images...), req.Urls...), req.ReferenceImages...)
	for _, ref := range []string{req.Image, req.InputReference, req.StartFrame} {
		if ref != "" {
			refs = append(refs, ref)
		}
	}
	unique := make([]string, 0, len(refs))
	seen := make(map[string]bool)
	for _, ref := range refs {
		if !seen[ref] {
			unique = append(unique, ref)
			seen[ref] = true
		}
	}
	if len(unique) > 1 {
		return fail("this FullBlast deployment supports one reference image per request")
	}
	if req.N != nil && *req.N != 1 {
		return fail("n must equal 1")
	}
	for key := range req.Metadata {
		// TapCanvas's internal routing annotations are not upstream parameters.
		if key != "vendor" && key != "taskKind" {
			return fail("unsupported FullBlast metadata field: " + key)
		}
	}
	out = payload{Model: req.Model, Prompt: req.Prompt, Duration: duration, Size: resolution, Metadata: metadata{Ratio: ratio, Seed: req.Seed}}
	for _, ref := range unique {
		u, err := url.Parse(ref)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return fail("reference image must be an absolute HTTP(S) URL")
		}
		out.Metadata.Media = append(out.Metadata.Media, media{Type: "reference_image", URL: ref})
	}
	req.Duration, req.Seconds, req.Resolution = duration, strconv.Itoa(duration), resolution
	return out, req, nil
}

func (a *TaskAdaptor) ValidateRequestAndSetAction(c *gin.Context, info *relaycommon.RelayInfo) *dto.TaskError {
	storage, err := common.GetBodyStorage(c)
	if err != nil {
		return service.TaskErrorWrapperLocal(err, "invalid_request", http.StatusBadRequest)
	}
	body, err := storage.Bytes()
	if err != nil {
		return service.TaskErrorWrapperLocal(err, "invalid_request", http.StatusBadRequest)
	}
	p, req, err := normalize(body)
	if err != nil {
		return service.TaskErrorWrapperLocal(err, "invalid_request", http.StatusBadRequest)
	}
	c.Set("task_request", req)
	c.Set("fullblast_payload", p)
	info.Action = constant.TaskActionGenerate
	return nil
}

// The shared task billing layer uses the model's duration/resolution price table.
func (a *TaskAdaptor) EstimateBilling(_ *gin.Context, _ *relaycommon.RelayInfo) map[string]float64 {
	return nil
}
func (a *TaskAdaptor) BuildRequestHeader(_ *gin.Context, req *http.Request, info *relaycommon.RelayInfo) error {
	req.Header.Set("Authorization", "Bearer "+info.ApiKey)
	req.Header.Set("Content-Type", "application/json")
	return nil
}
func (a *TaskAdaptor) BuildRequestBody(c *gin.Context, info *relaycommon.RelayInfo) (io.Reader, error) {
	v, ok := c.Get("fullblast_payload")
	p, valid := v.(payload)
	if !ok || !valid {
		return nil, fmt.Errorf("FullBlast normalized payload missing")
	}
	p.Model = info.UpstreamModelName
	body, err := common.Marshal(p)
	if err != nil {
		return nil, err
	}
	return bytes.NewReader(body), nil
}

func (a *TaskAdaptor) ParseTaskResult(body []byte) (*relaycommon.TaskInfo, error) {
	result, err := a.TaskAdaptor.ParseTaskResult(body)
	if err != nil {
		return nil, err
	}
	var response struct {
		Status   string `json:"status"`
		Metadata struct {
			URL string `json:"url"`
		} `json:"metadata"`
		Usage struct {
			OutputSeconds int    `json:"output_video_seconds"`
			Resolution    string `json:"resolution"`
		} `json:"usage"`
	}
	if err := common.Unmarshal(body, &response); err != nil {
		return nil, err
	}
	if result.Status == "" {
		return nil, fmt.Errorf("unrecognized FullBlast task status %q", response.Status)
	}
	result.Url = response.Metadata.URL
	result.OutputSeconds = response.Usage.OutputSeconds
	result.Resolution = strings.ToLower(response.Usage.Resolution)
	if result.Status == model.TaskStatusSuccess && result.Url == "" {
		return nil, fmt.Errorf("completed FullBlast task has no metadata.url")
	}
	return result, nil
}

func (a *TaskAdaptor) AdjustBillingOnComplete(task *model.Task, result *relaycommon.TaskInfo) int {
	if task == nil || result == nil || result.Status != model.TaskStatusSuccess {
		return 0
	}
	bc := task.PrivateData.BillingContext
	if bc == nil || result.OutputSeconds <= 0 {
		return 0
	}
	price, ok := model.VideoSpecPriceCNY(bc.OriginModelName, result.Resolution, result.OutputSeconds)
	if !ok {
		return 0
	}
	if ratio := bc.OtherRatios["channel_price"]; ratio > 0 {
		price *= ratio
	}
	return int(price * common.QuotaPerUnit * bc.GroupRatio * common.NormalizePriceRatio(bc.UserPriceRatio))
}
func (a *TaskAdaptor) GetChannelName() string { return "FullBlast Video" }
func (a *TaskAdaptor) GetModelList() []string { return []string{"wan3.0-video"} }
