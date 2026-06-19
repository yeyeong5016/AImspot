# 모든 더미 데이터는 현재 하드코딩 상태입니다 (추후 DB/모델로 이전 예정).
class AnalysesController < ApplicationController
  # ── 홈 페이지 ──────────────────────────────────────────────
  def new
    @features = [
      { icon: "💰", title: "돈이 되나요?", desc: "업종별 점포당 매출과 수익성을 분석합니다" },
      { icon: "⚔️", title: "경쟁이 심한가요?", desc: "동종 업종 점포 수와 폐업률을 분석합니다" },
      { icon: "🎓", title: "학생들이 좋아하나요?", desc: "20대 여성 매출 비중과 소비 패턴을 분석합니다" },
      { icon: "📋", title: "학생들은 뭘 원하나요?", desc: "성신여대 학생 수요조사 500건을 반영합니다" },
      { icon: "✨", title: "어떻게 차별화해야 하나요?", desc: "데이터 기반 AI 차별화 전략 3가지를 제안합니다" }
    ]

    @categories = [
      { label: "음식·카페", children: [
        { label: "카페·베이커리", children: [{ label: "커피-음료" }, { label: "제과점" }] },
        { label: "일반음식점", children: [{ label: "한식음식점" }, { label: "중식음식점" }, { label: "분식전문점" }] },
        { label: "주점", children: [{ label: "호프-간이주점" }, { label: "일반유흥주점" }] }
      ] },
      { label: "쇼핑·소매", children: [
        { label: "편의점", children: [{ label: "편의점" }] },
        { label: "슈퍼마켓", children: [{ label: "슈퍼마켓" }] }
      ] },
      { label: "뷰티·헬스", children: [{ label: "미용", children: [{ label: "미용실" }] }] },
      { label: "교육", children: [{ label: "학원", children: [{ label: "일반교습학원" }, { label: "예술학원" }] }] },
      { label: "생활서비스", children: [{ label: "수리", children: [{ label: "자동차수리" }] }] },
      { label: "여가·엔터테인먼트", children: [{ label: "오락", children: [{ label: "PC방" }] }] },
      { label: "의료", children: [{ label: "의원", children: [{ label: "일반의원" }] }] },
      { label: "전문서비스", children: [{ label: "컨설팅", children: [{ label: "경영컨설팅" }] }] },
      { label: "숙박·여행", children: [{ label: "숙박", children: [{ label: "게스트하우스" }] }] },
      { label: "자동차·운송", children: [{ label: "운송", children: [{ label: "대리운전" }] }] }
    ]

    @trade_areas = [
      { code: "A", label: "성신여대입구역 1번" },
      { code: "B", label: "성신여대입구역 4번" },
      { code: "C", label: "성신여대입구역 7번" },
      { code: "D", label: "보문역 8번" },
      { code: "E", label: "삼선동주민센터" }
    ]
    @stats = [
      { value: "500건", label: "학생 수요조사" },
      { value: "5개", label: "성신여대 상권" },
      { value: "2026년 1분기", label: "데이터 기준" }
    ]
  end

  # ── 상권 분석 리포트 페이지 ────────────────────────────────
  def show
    # 상권(지도 표시용 좌표 + 데이터 조회용 지역코드)
    @areas = [
      { code: "A", label: "성신여대입구역 1번", region_code: "3110303", lat: 37.5928, lng: 127.0168,
        polygon: [[37.5938, 127.0152], [37.5940, 127.0185], [37.5918, 127.0190], [37.5914, 127.0155]] },
      { code: "B", label: "성신여대입구역 4번", region_code: "3110296", lat: 37.5919, lng: 127.0151 },
      { code: "C", label: "성신여대입구역 7번", region_code: "3110301", lat: 37.5935, lng: 127.0179 },
      { code: "D", label: "보문역 8번", region_code: "3110302", lat: 37.5854, lng: 127.0193 },
      { code: "E", label: "삼선동주민센터", region_code: "3110300", lat: 37.5897, lng: 127.0079 }
    ]
    @station = { lat: 37.5926, lng: 127.0163, label: "성신여대입구역" }

    @code = params[:trdar_cd].presence || "A"
    @area = @areas.find { |a| a[:code] == @code } || @areas.first
    @biz  = params[:business_type].presence || "커피-음료"

    # 실제 데이터 기반 리포트 산출 (점수 + 모든 차트 + 학생 수요)
    user_input = {
      "업종" => @biz,
      "대분류" => params[:category_l].presence || "음식·카페",
      "중분류" => params[:category_m].presence || "카페·베이커리",
      "위치" => @area[:label],
      "지역코드" => @area[:region_code]
    }
    report = AnalysisReportService.call(
      user_input: user_input,
      store_sales_path: Rails.root.join("data", "store+sales.csv").to_s,
      survey_path: Rails.root.join("data", "survey.xlsx").to_s
    )

    @score           = report["score"]
    @grade           = report["grade"]
    @judge           = report["judge"]
    @stats           = report["stats"]
    @ai_summary      = report["ai_summary"]
    @ai_bullets      = report["ai_bullets"]
    @revenue         = report["revenue"]
    @competition     = report["competition"]
    @age             = report["age"]
    @age_average     = report["age_average"]
    @timeslot        = report["timeslot"]
    @problems        = report["problems"]
    @choice_criteria = report["choice_criteria"]
    @desired_biz     = report["desired_biz"]

    # 점수 상세(향후 Claude 입력/디버깅용)
    @score_result    = report["score_result"]
    @low_score_items = report["low_score_items"]
    @demand_data     = report["demand_data"]

    # AI 차별화 전략 (Gemini). 생성 실패 시 데이터 기반 폴백 카드 사용.
    @strategies = report["strategies"].presence || fallback_strategies
  end

  private

  # Gemini 호출 실패/키 미설정 시 보여줄 데이터 기반 폴백 전략
  def fallback_strategies
    items = (@low_score_items || []).first(3)
    pains = (@demand_data && @demand_data["아쉽거나_불편한_점"]) || []
    icons = ["🪑", "🍽️", "🕐"]
    cats  = ["공간 전략", "메뉴 전략", "운영 전략"]
    items.each_with_index.map do |it, i|
      {
        id: "fallback#{i}", icon: icons[i] || "✨", title: cats[i] || "보완 전략",
        body: "#{it['항목']} 보완: #{pains[i] || it['낮은_이유']}",
        chip: it["낮은_이유"], boost: 0, default_on: i.zero?
      }
    end
  end
end
