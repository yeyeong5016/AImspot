# frozen_string_literal: true

# 차별화 전략 생성 (Gemini 기반)
# ===========================================================================
# 점수 분석 결과(JSON) + 수요조사 데이터를 입력으로, 데이터 근거 기반의
# 차별화 전략 3가지(공간 / 메뉴 / 운영)를 생성한다.
#
# 핵심 규칙(프롬프트로 강제):
#  1) 가장 낮은 점수 항목을 우선 보완하는 방향으로 설계
#  2) 모든 전략은 수요조사/매출 데이터의 구체적 수치를 근거로 포함
#  3) 공간/메뉴/운영 각 1개, "전략명 + 실행방안 + 데이터근거" 형식
#  4) SNS·친절·일반 마케팅 같은 업종 불문 일반 조언 금지
#  5) 총평은 점수대별 톤 (높음=보완 위주 / 낮음=위험경고 + 수요기반 차별화)
class StrategyAdvisorService
  CATEGORIES = %w[공간 메뉴 운영].freeze

  RESPONSE_SCHEMA = {
    type: "OBJECT",
    properties: {
      overall_feedback: { type: "STRING" },
      strategies: {
        type: "ARRAY",
        items: {
          type: "OBJECT",
          properties: {
            category: { type: "STRING", enum: CATEGORIES },
            title: { type: "STRING" },
            action: { type: "STRING" },
            evidence: { type: "STRING" },
            expected_uplift: { type: "INTEGER" }
          },
          required: %w[category title action evidence expected_uplift],
          propertyOrdering: %w[category title action evidence expected_uplift]
        }
      }
    },
    required: %w[overall_feedback strategies],
    propertyOrdering: %w[overall_feedback strategies]
  }.freeze

  def self.call(input_data, temperature: 0.7)
    new(input_data).call(temperature: temperature)
  end

  def initialize(input_data)
    @input = input_data
  end

  def call(temperature: 0.7)
    GeminiClient.generate_json(build_prompt, schema: RESPONSE_SCHEMA, temperature: temperature)
  end

  private

  def build_prompt
    <<~PROMPT
      당신은 대학가 상권 데이터와 학생 수요조사를 근거로 창업 차별화 전략을 설계하는 전문가입니다.
      아래 [분석 데이터]만을 근거로, 추측이나 일반론 없이 전략을 작성하세요.

      [분석 데이터]
      #{JSON.pretty_generate(@input)}

      [작성 규칙]
      1. 위 데이터의 "낮은_점수_항목"을 우선적으로 보완하는 방향으로 전략을 설계한다.
         특히 점수가 낮은 항목일수록, 그 약점을 "수요조사" 응답으로 메우는 방식으로 접근한다.
      2. 반드시 "공간", "메뉴", "운영" 세 가지 카테고리로 각각 정확히 1개씩, 총 3개의 전략을 생성한다.
      3. 각 전략은 다음으로 구성한다:
         - title(전략명): 한 줄로 명확한 전략 이름
         - action(실행방안): 해당 업종에 바로 적용 가능한 구체적 실행 내용을 자연스러운
           문장으로 서술한다. 근거가 되는 구체적 수치와 수요조사 응답 문구를 이 문장 안에
           자연스럽게 녹여 넣는다.
         - evidence(데이터근거): 카드 하단에 들어갈 아주 짧은 태그. 핵심 수치 1~2개만 골라
           20자 이내로 압축한다. 가운뎃점(·)으로 구분하며, 문장·긴 나열·따옴표 인용은 금지한다.
           (예: "경쟁 4.5배 · 20대 38%", "폐업률 14%", "피크 17~21시 · 20대 38%")
      4. action 에는 추상적 표현 대신 반드시 구체적 수치 또는 수요조사 응답 문구를 포함한다.
      5. expected_uplift: 데이터 근거에 기반한 현실적인 월매출 기여 추정치(%, 정수).
      6. 금지: SNS 운영, 친절한 응대, 인테리어 분위기, 일반적 홍보/마케팅 등
         업종·상권과 무관한 일반 창업 조언은 절대 포함하지 않는다.
      7. overall_feedback(총평, 2~3문장):
         - 종합점수 60점 이상: "전반적으로 무난하나 낮은 항목을 보완하면 좋다"는 톤.
         - 종합점수 60점 미만: "위험 신호가 크다. 20대 학생 수요조사를 근거로 강한 차별화가 필요하다"는 톤.
      8. 모든 출력은 자연스러운 한국어로 작성한다.
    PROMPT
  end
end
