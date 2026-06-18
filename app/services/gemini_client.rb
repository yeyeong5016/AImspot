# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# Google Gemini API 호출 (generateContent, 구조화 JSON 출력)
# - 인증: ENV["GEMINI_API_KEY"] (.env 에서 로드)
# - 모델: ENV["GEMINI_MODEL"] (기본 gemini-2.0-flash)
class GeminiClient
  ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models"
  DEFAULT_MODEL = "gemini-2.5-flash"

  class Error < StandardError; end

  def self.generate_json(prompt, schema:, model: nil, temperature: 0.7)
    new(model).generate_json(prompt, schema: schema, temperature: temperature)
  end

  def initialize(model = nil)
    env_model = ENV["GEMINI_MODEL"].to_s.strip
    @model = model || (env_model.empty? ? DEFAULT_MODEL : env_model)
    @key = ENV["GEMINI_API_KEY"].to_s.strip
    raise Error, "GEMINI_API_KEY 가 설정되지 않았습니다 (.env 확인)" if @key.empty?
  end

  # 구조화 JSON 응답을 강제하고 파싱해서 Hash 로 반환
  def generate_json(prompt, schema:, temperature: 0.7)
    gen_config = {
      responseMimeType: "application/json",
      responseSchema: schema,
      temperature: temperature
    }
    # 2.5 계열은 thinking 이 기본 활성(응답 지연 큼) → 비활성화로 속도 확보
    gen_config[:thinkingConfig] = { thinkingBudget: 0 } if @model.start_with?("gemini-2.5")

    body = { contents: [{ parts: [{ text: prompt }] }], generationConfig: gen_config }
    raw = post(body)
    text = raw.dig("candidates", 0, "content", "parts", 0, "text")
    if text.nil? || text.strip.empty?
      reason = raw.dig("candidates", 0, "finishReason") || raw["promptFeedback"]
      raise Error, "Gemini 응답이 비어있습니다 (finishReason=#{reason})"
    end
    JSON.parse(text)
  end

  private

  # 일시적 오류(429/500/503/504)는 짧은 백오프로 재시도
  RETRYABLE = %w[429 500 502 503 504].freeze
  MAX_RETRIES = 2

  def post(body)
    uri = URI("#{ENDPOINT}/#{@model}:generateContent")
    payload = JSON.generate(body)

    attempt = 0
    loop do
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 60

      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req["x-goog-api-key"] = @key
      req.body = payload

      res = http.request(req)
      return JSON.parse(res.body) if res.is_a?(Net::HTTPSuccess)

      if RETRYABLE.include?(res.code) && attempt < MAX_RETRIES
        attempt += 1
        sleep(1.5 * attempt) # 1.5s, 3.0s 백오프
        next
      end
      raise Error, "Gemini API 오류 #{res.code}: #{res.body.to_s[0, 300]}"
    end
  end
end
