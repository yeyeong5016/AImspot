# frozen_string_literal: true

require "csv"
require "json"
require "digest"

# 상권 분석 리포트용 뷰 데이터 빌더
# ===========================================================================
# 폼 입력(업종/대분류/중분류/상권)을 받아, show 화면이 그리는 모든 데이터
# (종합 점수 + 6개 차트 + 학생 수요 목록)를 실제 데이터에서 계산해 반환한다.
#
# - 점수/low_score/demand 는 검증된 BusinessScoreService 를 재사용한다.
# - 차트 집계는 동일 데이터 로더/헬퍼(BusinessScoreService 의 public 메서드)를
#   재사용해 계산한다. 모든 수치는 데이터에서 산출하며 하드코딩하지 않는다.
#
# 반환 Hash 의 키는 컨트롤러가 그대로 @변수로 펼쳐 뷰에 전달한다.
class AnalysisReportService
  # 연령대 라벨 -> 매출 컬럼 키워드
  AGE_DEFS = [
    ["10대", "연령대_10"], ["20대", "연령대_20"], ["30대", "연령대_30"],
    ["40대", "연령대_40"], ["50대", "연령대_50"], ["60대+", "연령대_60"]
  ].freeze
  AGE_HIGHLIGHT = "20대"

  def self.call(user_input:, store_sales_path:, survey_path:)
    new(user_input, store_sales_path, survey_path).build
  end

  def initialize(user_input, store_sales_path, survey_path)
    @user_input = user_input
    @store_path = store_sales_path
    @survey_path = survey_path
    # 데이터 로더/헬퍼 재사용 (BusinessScoreService 의 메서드는 모두 public)
    @engine = BusinessScoreService.new(user_input, store_sales_path, survey_path)
  end

  def build
    store_rows, scol = @engine.load_store_sales_data(@store_path)
    survey_rows, scol_s = @engine.load_survey_data(@survey_path)

    code = @user_input["지역코드"].to_s
    region = store_rows.select { |r| r[scol["지역코드"]].to_s == code }
    sel_biz = @user_input["업종"]
    sel_major = @user_input["대분류"]

    # 대분류/중분류를 데이터로 보정 (폼에서 누락/불일치해도 경쟁도 집계가 정확하도록)
    category_map = @engine.apply_category_map(store_rows, scol)
    sel_major = category_map[sel_biz].first if category_map.key?(sel_biz)

    score = BusinessScoreService.call(
      user_input: @user_input, store_sales_path: @store_path, survey_path: @survey_path
    )

    age = age_chart(region, scol, sel_biz)
    age_avg = age_average(region, scol)
    timeslot = timeslot_chart(region, scol, sel_biz, survey_rows, scol_s)
    stats = display_stats(region, scol, sel_biz, sel_major, age, age_avg, timeslot)

    # Gemini 차별화 전략 (실패 시 nil → 컨트롤러가 데이터 기반 폴백)
    advisor = generate_strategies(score, stats, sel_biz, age_avg)

    {
      "score" => score["score_result"]["총점"],
      "grade" => score["score_result"]["등급"],
      "judge" => score["score_result"]["판정"],
      "ai_bullets" => ai_bullets(score),
      "ai_summary" => advisor ? advisor[:summary] : ai_summary(score, stats, sel_biz),
      "strategies" => advisor ? advisor[:strategies] : nil,
      "revenue" => revenue_chart(region, scol, sel_biz),
      "competition" => competition_chart(region, scol, sel_biz, sel_major),
      "age" => age,
      "age_average" => age_avg,
      "timeslot" => timeslot,
      "problems" => problems_chart(survey_rows, scol_s),
      "choice_criteria" => choice_criteria(survey_rows, scol_s),
      "desired_biz" => desired_biz(survey_rows, scol_s),
      "stats" => stats,
      # 원본(향후 Claude 입력 / 디버깅용)
      "score_result" => score["score_result"],
      "low_score_items" => score["low_score_items"],
      "demand_data" => score["demand_data"]
    }
  end

  private

  # 지역 내 업종별 점포당 월매출(원) 맵 — 메모이즈
  def per_store_map(region, scol)
    @per_store_map ||= begin
      col_pps = scol["점포당월매출"]
      col_sales, col_store = scol["당월매출"], scol["점포수"]
      map = {}
      @engine.group_rows(region, scol["업종"]).each do |biz, rs|
        map[biz] =
          if col_pps
            @engine.mean(rs.map { |r| @engine.num(r[col_pps]) })
          else
            stores = rs.sum { |r| @engine.num(r[col_store]) }
            stores.positive? ? rs.sum { |r| @engine.num(r[col_sales]) } / stores : 0.0
          end
      end
      map
    end
  end

  # 점포당 월매출 순위 (백만원 단위, 상위 10 + 선택 업종)
  def revenue_chart(region, scol, sel_biz)
    per = per_store_map(region, scol)
    top = per.sort_by { |_biz, v| -v }.first(10).to_h
    top[sel_biz] = per[sel_biz] if per.key?(sel_biz) && !top.key?(sel_biz)
    top.map do |biz, v|
      { "name" => biz, "value" => (v / 1_000_000.0).round, "highlight" => biz == sel_biz }
    end
  end

  # 같은 대분류 점포수: { median:, count:(선택 업종), ratio: }
  def competition_values(region, scol, sel_biz, sel_major)
    @competition_values ||= begin
      major_rows = region.select { |r| r[scol["대분류"]] == sel_major }
      by_biz = {}
      @engine.group_rows(major_rows, scol["업종"]).each { |biz, rs| by_biz[biz] = rs.sum { |r| @engine.num(r[scol["점포수"]]) } }
      if by_biz.empty?
        { median: 0.0, count: 0, ratio: nil }
      else
        med = @engine.median(by_biz.values)
        cnt = by_biz.fetch(sel_biz, 0).to_f
        { median: med, count: cnt, ratio: med.positive? ? cnt / med : nil }
      end
    end
  end

  # 경쟁도 차트 — 같은 대분류 점포수 중앙값 vs 선택 업종 점포수
  def competition_chart(region, scol, sel_biz, sel_major)
    c = competition_values(region, scol, sel_biz, sel_major)
    return [] if c[:count].zero? && c[:median].zero?

    [
      { "name" => "#{sel_major} 중앙값", "value" => c[:median].round, "kind" => "muted" },
      { "name" => sel_biz, "value" => c[:count].round, "kind" => "danger" }
    ]
  end

  # 연령대별 매출 비중 (%)
  def age_chart(region, scol, sel_biz)
    rows = region.select { |r| r[scol["업종"]] == sel_biz }
    cols = age_columns(scol)
    sums = AGE_DEFS.map { |label, key| [label, rows.sum { |r| @engine.num(r[cols[key]]) }] }
    total = sums.sum { |_l, v| v }
    sums.map do |label, v|
      { "name" => label, "value" => total.positive? ? (v / total * 100).round : 0, "highlight" => label == AGE_HIGHLIGHT }
    end
  end

  # 연령대 평균선 — 지역 내 전체 업종의 20대 매출 비중 평균
  def age_average(region, scol)
    cols = age_columns(scol)
    twenty_key = AGE_DEFS.find { |label, _| label == AGE_HIGHLIGHT }.last
    shares = []
    @engine.group_rows(region, scol["업종"]).each do |_biz, rs|
      total = AGE_DEFS.sum { |_l, key| rs.sum { |r| @engine.num(r[cols[key]]) } }
      next unless total.positive?

      twenties = rs.sum { |r| @engine.num(r[cols[twenty_key]]) }
      shares << (twenties / total * 100)
    end
    shares.empty? ? 0 : (shares.sum / shares.size).round
  end

  # 시간대별 매출(백만원) vs 학생 이용(응답수)
  def timeslot_chart(region, scol, sel_biz, survey_rows, scol_s)
    rows = region.select { |r| r[scol["업종"]] == sel_biz }
    time_cols = scol["_time_cols"]
    slot_counter = Hash.new(0)
    col_time = scol_s["이용시간"]
    if col_time
      @engine.column_values(survey_rows, col_time).each do |cell|
        @engine.split_multi(cell).each do |tok|
          BusinessScoreService::SURVEY_TIME_KEYWORDS.each do |kw, slot|
            if tok.include?(kw)
              slot_counter[slot] += 1
              break
            end
          end
        end
      end
    end
    BusinessScoreService::TIME_SLOTS.map do |slot|
      col = time_cols[slot]
      sales = col ? (rows.sum { |r| @engine.num(r[col]) } / 1_000_000.0).round : 0
      { "name" => slot, "sales" => sales, "students" => slot_counter[slot] }
    end
  end

  # 상권 문제점 TOP5 (응답수)
  def problems_chart(survey_rows, scol_s)
    counted_tokens(survey_rows, scol_s["불편점"], exclude: ["없음"], n: 5)
      .map { |label, count| { "name" => label, "value" => count } }
  end

  # 학생 선택 기준 TOP3 (새 가게에서 중요하게 보는 요소)
  def choice_criteria(survey_rows, scol_s)
    col = find_header(survey_rows, ["중요", "요소"])
    ranked_list(survey_rows, col, 3)
  end

  # 희망 업종 TOP3
  def desired_biz(survey_rows, scol_s)
    ranked_list(survey_rows, scol_s["희망업종_객관식"], 3)
  end

  # 뷰 캡션/통계용 파생값 (모두 데이터에서 산출)
  def display_stats(region, scol, sel_biz, sel_major, age, age_avg, timeslot)
    per = per_store_map(region, scol)
    ranked = per.sort_by { |_b, v| -v }.map(&:first)
    rank = per.key?(sel_biz) ? ranked.index(sel_biz) + 1 : nil
    total = ranked.size
    sel_rev = per.key?(sel_biz) ? (per[sel_biz] / 1_000_000.0).round : 0

    comp = competition_values(region, scol, sel_biz, sel_major)
    rate = closure_rate(region.select { |r| r[scol["업종"]] == sel_biz }, scol)

    age20 = (age.find { |a| a["name"] == AGE_HIGHLIGHT } || {})["value"].to_i
    sales_peak = (timeslot.max_by { |t| t["sales"] } || {})["name"]
    student_peak = (timeslot.max_by { |t| t["students"] } || {})["name"]

    {
      same_biz_stores: comp[:count].round,
      closure_rate: rate.round(1),
      per_store_revenue: sel_rev,
      revenue_rank: rank,
      revenue_total: total,
      comp_ratio: comp[:ratio] ? comp[:ratio].round(1) : nil,
      comp_median: comp[:median].round,
      comp_count: comp[:count].round,
      age_20s: age20,
      age_20s_diff: age20 - age_avg,
      sales_peak: sales_peak,
      student_peak: student_peak,
      market_badge: market_badge(rank, total),
      competition_badge: competition_badge(comp[:ratio]),
      age_badge: age_badge(age20, age_avg)
    }
  end

  GREEN = { bg: "#f0fdf4", color: "#16a34a" }.freeze
  AMBER = { bg: "#fefce8", color: "#f59e0b" }.freeze
  RED   = { bg: "#fef2f2", color: "#ef4444" }.freeze
  GRAY  = { bg: "var(--color-zinc-bg)", color: "#71717a" }.freeze

  def market_badge(rank, total)
    return GRAY.merge(text: "데이터 부족") if rank.nil? || total.zero?

    case rank.to_f / total
    when 0.0..0.25 then GREEN.merge(text: "상위")
    when 0.25..0.50 then GREEN.merge(text: "중상위")
    when 0.50..0.75 then AMBER.merge(text: "중위")
    else RED.merge(text: "하위")
    end
  end

  def competition_badge(ratio)
    return GRAY.merge(text: "데이터 부족") if ratio.nil?
    return RED.merge(text: "경쟁 과열") if ratio >= 2.0
    return AMBER.merge(text: "경쟁 보통") if ratio >= 1.0

    GREEN.merge(text: "경쟁 여유")
  end

  def age_badge(age20, avg)
    age20 >= avg ? GREEN.merge(text: "학생 친화") : AMBER.merge(text: "보통")
  end

  def closure_rate(rows, scol)
    return 0.0 if rows.empty?

    col_rate = scol["폐업률"]
    vals = col_rate ? rows.map { |r| r[col_rate] }.reject { |v| v.nil? || v.to_s.strip.empty? } : []
    return @engine.mean(rows.map { |r| @engine.num(r[col_rate]) }) unless vals.empty?

    closed = rows.sum { |r| @engine.num(r[scol["폐업점포수"]]) }
    total = rows.sum { |r| @engine.num(r[scol["점포수"]]) }
    total.positive? ? (closed / total * 100) : 0.0
  end

  STRATEGY_ICONS = { "공간" => "🪑", "메뉴" => "🍽️", "운영" => "🕐" }.freeze

  # Gemini 로 차별화 전략 생성 → 뷰(_strategy 파셜) 구조로 매핑.
  # 키 없음/네트워크 오류/파싱 실패 시 nil 반환(폴백은 호출측에서 처리).
  def generate_strategies(score, stats, sel_biz, age_avg)
    return nil if ENV["GEMINI_API_KEY"].to_s.strip.empty?

    input = {
      "업종" => sel_biz,
      "위치" => @user_input["위치"],
      "종합점수" => score["score_result"]["총점"],
      "등급" => score["score_result"]["등급"],
      "판정" => score["score_result"]["판정"],
      "항목별_점수" => score["score_result"]["항목별_점수"],
      "낮은_점수_항목" => score["low_score_items"],
      "추가_지표" => {
        "20대_매출_비중(%)" => stats[:age_20s],
        "지역_20대_평균(%)" => age_avg,
        "20대_평균대비_차이(%p)" => stats[:age_20s_diff],
        "경쟁도_배율" => stats[:comp_ratio],
        "폐업률(%)" => stats[:closure_rate],
        "매출_피크" => stats[:sales_peak],
        "학생_이용_피크" => stats[:student_peak]
      },
      "수요조사" => score["demand_data"]
    }

    result = strategy_with_cache(input)
    list = result && result["strategies"]
    return nil if list.nil? || list.empty?

    strategies = list.each_with_index.map do |s, i|
      {
        id: s["category"],
        icon: STRATEGY_ICONS[s["category"]] || "✨",
        title: s["title"],
        body: s["action"],
        chip: s["evidence"],
        boost: s["expected_uplift"].to_i,
        default_on: i.zero?
      }
    end
    { summary: result["overall_feedback"], strategies: strategies }
  rescue StandardError => e
    Rails.logger.warn("[StrategyAdvisor] #{e.class}: #{e.message}") if defined?(Rails)
    nil
  end

  # 동일 입력 반복 호출 방지(캐시 사용 가능 환경에서만). dev 캐시 미사용 시 그대로 호출.
  def strategy_with_cache(input)
    if defined?(Rails) && Rails.respond_to?(:cache) && Rails.cache
      key = "strategy/#{Digest::SHA256.hexdigest(JSON.generate(input))}"
      Rails.cache.fetch(key, expires_in: 6 * 60 * 60) { StrategyAdvisorService.call(input) }
    else
      StrategyAdvisorService.call(input)
    end
  end

  # 데이터 기반 분석 요약 (Gemini 실패 시 폴백)
  def ai_summary(score, stats, sel_biz)
    parts = []
    if stats[:comp_ratio]
      level = stats[:comp_ratio] >= 2.0 ? "높은" : (stats[:comp_ratio] >= 1.0 ? "보통" : "낮은")
      parts << "#{sel_biz}의 동종 점포 수는 동일 대분류 중앙값 대비 #{stats[:comp_ratio]}배로 경쟁도가 #{level} 편입니다."
    end
    if stats[:revenue_rank]
      parts << "점포당 월매출은 지역 #{stats[:revenue_total]}개 업종 중 #{stats[:revenue_rank]}위입니다."
    end
    diff = stats[:age_20s_diff]
    sign = diff >= 0 ? "+#{diff}" : diff.to_s
    parts << "20대 매출 비중은 #{stats[:age_20s]}%로 지역 평균 대비 #{sign}%p입니다."
    parts << "종합점수 #{score['score_result']['총점']}점(#{score['score_result']['등급']}등급)."
    parts.join(" ")
  end

  # ── 헬퍼 ────────────────────────────────────────────────────────────────
  def age_columns(scol)
    # scol 에는 연령대 컬럼이 없으므로 store 헤더에서 직접 탐지(키워드 -> 실제 컬럼)
    @age_columns ||= begin
      headers = scol["_headers"] || store_headers
      AGE_DEFS.each_with_object({}) do |(_label, key), acc|
        acc[key] = headers.find { |c| c.include?(key) && c.include?("매출") }
      end
    end
  end

  def store_headers
    @store_headers ||= CSV.open(@store_path, encoding: "bom|utf-8", &:readline).map { |h| h.to_s.strip }
  end

  def counted_tokens(rows, col, exclude: [], n: 5)
    return [] if col.nil?

    counter = Hash.new(0)
    @engine.column_values(rows, col).each do |cell|
      @engine.split_multi(cell).each do |tok|
        counter[tok] += 1 if !tok.empty? && exclude.none? { |e| tok.include?(e) }
      end
    end
    @engine.most_common(counter, n)
  end

  # 뷰(ERB)에서 c[:rank]/c[:label]/c[:count] 로 접근하므로 심볼 키로 반환
  def ranked_list(rows, col, n)
    counted_tokens(rows, col, n: n).each_with_index.map do |(label, count), i|
      { rank: i + 1, label: label, count: count }
    end
  end

  # 헤더 키워드로 컬럼명 직접 탐지(후보 상수에 없는 컬럼용)
  def find_header(rows, keywords)
    return nil if rows.empty?

    rows.first.keys.find { |h| keywords.any? { |k| h.to_s.include?(k) } }
  end

  # AI 분석 불릿 — 현재는 데이터 기반 임시(저점 항목 사유). 추후 Claude 로 대체.
  def ai_bullets(score)
    bullets = score["low_score_items"].map { |it| it["낮은_이유"] }
    pains = score.dig("demand_data", "아쉽거나_불편한_점") || []
    bullets += pains.first(2).map { |p| "학생 의견: #{p}" }
    bullets.first(4)
  end
end
