# frozen_string_literal: true

require "csv"
require "json"
require "set"

# 창업 적합 점수 — 규칙 기반 엔진
# ===========================================================================
# data/store+sales.csv (상권/매출) + data/survey.xlsx (수요조사) 를 읽어
# user_input 에 대한 100점 만점 점수와 LLM 입력용 Hash(JSON) 를 생성한다.
#
# 설계 원칙
# - 점수 계산에 들어가는 값(매출/점포수/폐업률/중앙값/언급수/피크시간대 등)은
#   절대 하드코딩하지 않고 모두 데이터에서 읽어 계산한다.
# - 하드코딩 허용: 점수 기준(임계값/배점), 컬럼명 후보, CATEGORY_MAP(구조),
#   업종 매핑 규칙(BUSINESS_ALIASES), 시간대 매핑 규칙.
# - CATEGORY_MAP(업종 -> [대분류, 중분류])은 드리프트 방지를 위해 CSV의
#   대분류/중분류 컬럼에서 데이터 기반으로 생성하고, user_input 검증에 사용한다.
#
# 사용:
#   BusinessScoreService.call(user_input:, store_sales_path:, survey_path:)
class BusinessScoreService
  # ── 하드코딩 허용 ① : 컬럼명 후보 (실제 컬럼명이 바뀌어도 자동 탐지) ──
  STORE_COLUMN_CANDIDATES = {
    "지역코드"     => ["지역코드", "지역_코드", "상권코드", "상권_코드", "trdar_cd"],
    "지역"         => ["지역", "지역명", "상권명", "상권_명", "trdar_cd_nm"],
    "업종"         => ["서비스_업종_코드_명", "서비스업종코드명", "업종명", "업종_명", "업종"],
    "대분류"       => ["대분류", "업종_대분류", "대분류명", "대분류_명"],
    "중분류"       => ["중분류", "업종_중분류", "중분류명", "중분류_명"],
    "당월매출"     => ["당월_매출_금액", "당월매출금액", "월_매출_금액", "월매출", "매출_금액", "매출금액"],
    "점포당월매출" => ["점포당_월매출_금액", "점포당_월매출", "점포당_매출_금액", "점포당_매출", "점포당매출"],
    "점포수"       => ["전체_점포_수", "점포_수", "점포수", "유사_업종_점포_수", "store_co"],
    "폐업률"       => ["폐업_률", "폐업률", "폐업_율", "closure_rate"],
    "폐업점포수"   => ["폐업_점포_수", "폐업점포수", "폐업_수"]
  }.freeze

  SURVEY_COLUMN_CANDIDATES = {
    "자주이용업종"   => ["자주 이용하는 업종", "자주_이용하는_업종", "자주이용업종", "자주 이용"],
    "이용시간"       => ["상권 이용 시간", "상권_이용_시간", "이용 시간대", "이용시간", "이용 시간"],
    "희망업종_객관식" => ["희망 업종 (객관식)", "희망 업종", "희망업종", "더 생겼으면", "새로 생겼으면"],
    "희망업종_주관식" => ["희망_업종_주관식", "희망업종주관식", "희망 업종 주관식"],
    "부족업종"       => ["부족한_업종", "부족업종", "부족한 업종"],
    "불편점"         => ["불편", "아쉬", "불편한 점", "아쉬운 점"],
    "부족디테일"     => ["부족한_디테일", "부족디테일", "부족한 디테일"],
    "희망디테일"     => ["희망_디테일", "희망디테일", "희망 디테일"]
  }.freeze

  # ── 하드코딩 허용 ② : 점수 기준(배점/임계값). 값이 아니라 규칙. ──
  # 1) 점포당 월매출: 상위 누적비율 미만이면 해당 배점
  SALES_QUARTILE_RULES = [[0.25, 30], [0.50, 20], [0.75, 10], [1.01, 0]].freeze
  # 2) 경쟁도: 비율이 하한 이상이면 해당 배점 (큰 비율부터 평가)
  COMPETITION_RULES = [[3.0, 0], [2.0, 5], [1.5, 10], [1.0, 15], [0.7, 20], [0.0, 25]].freeze
  # 3) 폐업률(%): 값이 상한 이하이면 해당 배점 (작은 상한부터 평가)
  CLOSURE_RULES = [[0.0, 20], [5.0, 15], [10.0, 10], [Float::INFINITY, 0]].freeze
  # 4) 더 생겼으면 좋을 가게: 언급 순위 -> 배점
  WISH_RANK_RULES = { 1 => 15, 2 => 12, 3 => 9, 4 => 6, 5 => 3 }.freeze
  # 5) 이용 시간대: 피크 구간 차이 -> 배점
  TIME_DIFF_RULES = { 0 => 7, 1 => 4 }.freeze
  # 6) 자주 이용하는 업종: 포함되면 배점
  FREQUENT_USE_POINT = 3

  # 등급: 전체 (지역코드 × 업종) 종합점수 "분포"의 백분위 기준
  #  A=상위 20%, B=상위 20~50%, C=상위 50~80%, D=하위 20%
  #  (frac_above = 나보다 높은 점수 조합의 비율)
  GRADE_PERCENTILES = [[0.20, "A", "창업 적합"], [0.50, "B", "창업 검토 가능"],
                       [0.80, "C", "신중 검토"], [Float::INFINITY, "D", "창업 비추천"]].freeze

  LOW_SCORE_THRESHOLDS = {
    "자주_이용하는_업종" => 0,
    "더_생겼으면_좋을_가게" => 6,
    "점포당_월매출_순위" => 10,
    "상권_이용_시간대" => 0,
    "폐업률" => 10,
    "경쟁도" => 10
  }.freeze

  TIME_SLOTS = ["00~06", "06~11", "11~14", "14~17", "17~21", "21~24"].freeze

  # ── 하드코딩 허용 ③ : 업종 매핑 규칙 (설문 자유응답/광의어 -> 표준 업종) ──
  BUSINESS_ALIASES = {
    "카페" => "커피-음료", "커피" => "커피-음료", "스터디카페" => "커피-음료", "디저트" => "커피-음료",
    "베이커리" => "제과점", "빵" => "제과점", "제과" => "제과점",
    "분식" => "분식전문점", "떡볶이" => "분식전문점",
    "한식" => "한식음식점", "중식" => "중식음식점", "양식" => "양식음식점", "일식" => "일식음식점",
    "호프" => "호프-간이주점", "주점" => "호프-간이주점", "술집" => "호프-간이주점", "포차" => "호프-간이주점",
    "편의점" => "편의점", "치킨" => "치킨전문점", "패스트푸드" => "패스트푸드점",
    "미용" => "미용실", "네일" => "미용실", "헤어" => "미용실",
    "학원" => "일반교습학원", "노래방" => "노래방", "pc방" => "PC방", "피씨방" => "PC방"
  }.freeze

  # 설문 시간 표현 -> 매출 시간대 슬롯 매핑 규칙
  SURVEY_TIME_KEYWORDS = {
    "새벽" => "00~06",
    "아침" => "06~11", "오전" => "06~11",
    "점심" => "11~14",
    "오후" => "14~17",
    "저녁" => "17~21",
    "밤" => "21~24", "야간" => "21~24", "심야" => "21~24"
  }.freeze

  KEYWORD_STOPWORDS = %w[
    가게 공간 정도 부분 경우 느낌 사람 이용 근처 주변 학교 학생 상권 많이 너무 그냥
    약간 필요 생각 때문 조금 우리 여기 거의 매장 업종 관련 전체 위치 에서 보다 하는
    있는 없는 같은 정말 진짜 지역 성신 여대
  ].to_set.freeze

  TRAILING_PRED = %w[합니다 습니다 하다 했다 되다 된다 있다 없다 같다].freeze
  TRAILING_JOSA = %w[으로 에서 에게 이나 보다 처럼 까지 부터 이 가 을 를 은 는 의 에 로 와 과 도 만].freeze

  MULTI_DELIMS = %r{[|/,;]+}

  # ───────────────────────────────────────────────────────────────────────
  def self.call(user_input:, store_sales_path:, survey_path:)
    new(user_input, store_sales_path, survey_path).analyze
  end

  # 전체 (지역코드 × 업종) 조합의 종합점수 분포(오름차순). 데이터 mtime 기준 프로세스 캐시.
  def self.score_distribution(store_sales_path:, survey_path:)
    @distribution_cache ||= {}
    key = [store_sales_path, survey_path,
           (begin; File.mtime(store_sales_path).to_i; rescue StandardError; 0; end),
           (begin; File.mtime(survey_path).to_i; rescue StandardError; 0; end)]
    @distribution_cache[key] ||= new({}, store_sales_path, survey_path).compute_distribution
  end

  # 분포 백분위로 등급 산정. distribution 은 오름차순 정렬된 점수 배열.
  def self.grade_by_percentile(total, distribution)
    return ["D", "창업 비추천"] if distribution.nil? || distribution.empty?

    frac_above = distribution.count { |s| s > total }.to_f / distribution.size
    GRADE_PERCENTILES.each do |thr, g, j|
      return [g, j] if frac_above < thr
    end
    ["D", "창업 비추천"]
  end

  def initialize(user_input, store_sales_path, survey_path)
    @user_input = user_input
    @store_sales_path = store_sales_path
    @survey_path = survey_path
  end

  def analyze
    sel_biz   = @user_input["업종"]
    sel_major = @user_input["대분류"]
    sel_mid   = @user_input["중분류"]
    region_code = @user_input["지역코드"].to_s

    # 1) 로딩
    store_rows, scolmap = load_store_sales_data(@store_sales_path)
    survey_rows, scolmap_s = load_survey_data(@survey_path)
    category_map = apply_category_map(store_rows, scolmap)
    canonical = category_map.keys

    # 2) CATEGORY_MAP 검증 (불일치 시 데이터값으로 보정)
    if category_map.key?(sel_biz)
      data_major, data_mid = category_map[sel_biz]
      sel_major = data_major if data_major != sel_major
      sel_mid = data_mid if data_mid != sel_mid
    end

    # 3) 지역코드 필터 (위치 문자열은 표시용 — 필터에 사용하지 않음)
    code_col = scolmap["지역코드"]
    region_rows = store_rows.select { |r| r[code_col].to_s == region_code }

    # 4) 항목별 점수
    s_sales, d_sales = calculate_sales_score(region_rows, scolmap, sel_biz)
    s_comp,  d_comp  = calculate_competition_score(region_rows, scolmap, sel_biz, sel_major)
    s_close, d_close = calculate_closure_score(region_rows, scolmap, sel_biz)
    s_wish,  d_wish  = calculate_wish_score(survey_rows, scolmap_s, sel_biz, canonical)
    s_time,  d_time  = calculate_time_score(region_rows, scolmap, sel_biz, survey_rows, scolmap_s)
    s_freq,  d_freq  = calculate_frequent_use_score(survey_rows, scolmap_s, sel_biz, sel_mid, canonical)

    item_scores = {
      "점포당_월매출_순위" => s_sales, "경쟁도" => s_comp, "폐업률" => s_close,
      "더_생겼으면_좋을_가게" => s_wish, "상권_이용_시간대" => s_time, "자주_이용하는_업종" => s_freq
    }
    item_details = {
      "점포당_월매출_순위" => d_sales, "경쟁도" => d_comp, "폐업률" => d_close,
      "더_생겼으면_좋을_가게" => d_wish, "상권_이용_시간대" => d_time, "자주_이용하는_업종" => d_freq
    }
    item_max = {
      "점포당_월매출_순위" => 30, "경쟁도" => 25, "폐업률" => 20,
      "더_생겼으면_좋을_가게" => 15, "상권_이용_시간대" => 7, "자주_이용하는_업종" => 3
    }

    total = item_scores.values.sum
    distribution = self.class.score_distribution(store_sales_path: @store_sales_path, survey_path: @survey_path)
    grade, judge = self.class.grade_by_percentile(total, distribution)

    # 5) 개선 포인트(주관식 반복 키워드) + low_score + demand
    improve_points = extract_keywords(column_values(survey_rows, scolmap_s["불편점"]), 3)
    if improve_points.empty?
      improve_points = extract_keywords(
        column_values(survey_rows, scolmap_s["부족디테일"]) +
        column_values(survey_rows, scolmap_s["희망디테일"]), 3
      )
    end

    low_items = extract_low_score_items(item_scores, item_details, item_max, improve_points)
    demand = extract_demand_data(survey_rows, scolmap_s)

    {
      "user_input" => {
        "업종" => @user_input["업종"],
        "대분류" => sel_major,
        "중분류" => sel_mid,
        "위치" => @user_input["위치"].to_s,
        "지역코드" => region_code
      },
      "score_result" => {
        "총점" => total,
        "등급" => grade,
        "판정" => judge,
        "항목별_점수" => {
          "점포당_월매출_순위" => "#{s_sales}/30",
          "경쟁도" => "#{s_comp}/25",
          "폐업률" => "#{s_close}/20",
          "더_생겼으면_좋을_가게" => "#{s_wish}/15",
          "상권_이용_시간대" => "#{s_time}/7",
          "자주_이용하는_업종" => "#{s_freq}/3"
        }
      },
      "low_score_items" => low_items,
      "demand_data" => demand
    }
  end

  # 모든 (지역코드 × 업종) 조합의 종합점수 목록(오름차순) — 등급 분포 산정용
  def compute_distribution
    store_rows, scol = load_store_sales_data(@store_sales_path)
    survey_rows, scol_s = load_survey_data(@survey_path)
    category_map = apply_category_map(store_rows, scol)
    canonical = category_map.keys

    totals = []
    store_rows.group_by { |r| r[scol["지역코드"]].to_s }.each_value do |region_rows|
      region_rows.map { |r| r[scol["업종"]] }.compact.uniq.each do |biz|
        next unless category_map.key?(biz)

        maj, mid = category_map[biz]
        totals << (
          calculate_sales_score(region_rows, scol, biz)[0] +
          calculate_competition_score(region_rows, scol, biz, maj)[0] +
          calculate_closure_score(region_rows, scol, biz)[0] +
          calculate_wish_score(survey_rows, scol_s, biz, canonical)[0] +
          calculate_time_score(region_rows, scol, biz, survey_rows, scol_s)[0] +
          calculate_frequent_use_score(survey_rows, scol_s, biz, mid, canonical)[0]
        )
      end
    end
    totals.sort
  end

  # ── 데이터 로딩 ─────────────────────────────────────────────────────────
  def load_store_sales_data(path)
    table = CSV.read(path, headers: true, encoding: "bom|utf-8")
    headers = table.headers.map { |h| h.to_s.strip }
    rows = table.map do |row|
      headers.each_with_object({}) { |h, acc| acc[h] = row[h] }
    end
    colmap = detect_columns(headers, STORE_COLUMN_CANDIDATES)
    # 시간대 컬럼 자동 탐지(슬롯 -> 실제 컬럼명)
    time_cols = {}
    TIME_SLOTS.each do |slot|
      col = headers.find { |c| c.include?(slot) && c.include?("시간대") }
      time_cols[slot] = col if col
    end
    colmap["_time_cols"] = time_cols
    [rows, colmap]
  end

  def load_survey_data(path)
    require "roo"
    xlsx = Roo::Excelx.new(path)
    sheet = xlsx.sheet(0)
    headers = sheet.row(1).map { |h| h.to_s.strip }
    rows = (2..sheet.last_row).map do |i|
      values = sheet.row(i)
      headers.each_with_index.each_with_object({}) { |(h, idx), acc| acc[h] = values[idx] }
    end
    colmap = detect_columns(headers, SURVEY_COLUMN_CANDIDATES)
    [rows, colmap]
  end

  def apply_category_map(store_rows, scolmap)
    col_b, col_l, col_m = scolmap["업종"], scolmap["대분류"], scolmap["중분류"]
    map = {}
    store_rows.each do |r|
      biz = r[col_b]
      next if biz.nil? || biz.to_s.strip.empty?

      map[biz.to_s] ||= [r[col_l].to_s, r[col_m].to_s]
    end
    map
  end

  # ── 공통 유틸 ───────────────────────────────────────────────────────────
  def detect_columns(columns, candidates)
    cols = columns.map { |c| c.to_s.strip }
    resolved = {}
    candidates.each do |logical, cand_list|
      found = nil
      cand_list.each do |cand|        # 1) 정확 일치
        found = cols.find { |c| c == cand }
        break if found
      end
      unless found                    # 2) 부분 일치
        cand_list.each do |cand|
          found = cols.find { |c| c.include?(cand) || cand.include?(c) }
          break if found
        end
      end
      resolved[logical] = found
    end
    resolved
  end

  def num(v)
    return 0.0 if v.nil?
    return v.to_f if v.is_a?(Numeric)

    s = v.to_s.strip
    s.empty? ? 0.0 : s.to_f
  end

  def split_multi(value)
    return [] if value.nil?

    value.to_s.split(MULTI_DELIMS).map(&:strip).reject(&:empty?)
  end

  def column_values(rows, col)
    return [] if col.nil?

    rows.map { |r| r[col] }.reject { |v| v.nil? || v.to_s.strip.empty? }
  end

  def median(values)
    return 0.0 if values.empty?

    s = values.map(&:to_f).sort
    n = s.size
    n.odd? ? s[n / 2] : (s[(n / 2) - 1] + s[n / 2]) / 2.0
  end

  def match_business(token, canonical)
    t = token.to_s.strip
    return nil if t.empty?

    nt = t.delete("- ")
    # 1) 정확 일치
    exact = canonical.find { |b| b == t }
    return exact if exact

    # 2) 부분 일치
    canonical.each do |b|
      nb = b.delete("- ")
      return b if !nb.empty? && (nt.include?(nb) || nb.include?(nt))
    end
    # 3) 별칭 규칙
    BUSINESS_ALIASES.each do |kw, target|
      return target if t.include?(kw) && canonical.include?(target)
    end
    nil
  end

  def normalize_keyword(tok)
    TRAILING_PRED.each do |suf|       # '부족하다' -> '부족'
      if tok.end_with?(suf) && tok.length > suf.length
        tok = tok[0...(tok.length - suf.length)]
        break
      end
    end
    TRAILING_JOSA.each do |suf|       # '가게가' -> '가게'
      if tok.end_with?(suf) && (tok.length - suf.length) >= 2
        tok = tok[0...(tok.length - suf.length)]
        break
      end
    end
    tok
  end

  def extract_keywords(texts, top_n = 3)
    counter = Hash.new(0)
    texts.each do |txt|
      next if txt.nil?

      txt.to_s.scan(/[가-힣]{2,}/).each do |raw|
        tok = normalize_keyword(raw)
        next if tok.length < 2 || KEYWORD_STOPWORDS.include?(tok)

        counter[tok] += 1
      end
    end
    most_common(counter, top_n).map(&:first)
  end

  # Counter.most_common 동등 — 빈도 내림차순, 동률은 첫 등장 순서 유지
  def most_common(counter, n = nil)
    sorted = counter.each_with_index.sort_by { |(_k, v), idx| [-v, idx] }.map(&:first)
    n ? sorted.first(n) : sorted
  end

  # ── 점수 항목별 계산 — [점수, detail] 반환 ──────────────────────────────
  def calculate_sales_score(region_rows, scolmap, sel_biz)
    col_b = scolmap["업종"]
    col_pps = scolmap["점포당월매출"]
    col_sales, col_store = scolmap["당월매출"], scolmap["점포수"]

    grouped = group_rows(region_rows, col_b)
    per_store = {}
    if col_pps
      grouped.each { |biz, rs| per_store[biz] = mean(rs.map { |r| num(r[col_pps]) }) }
    else
      grouped.each do |biz, rs|
        sales = rs.sum { |r| num(r[col_sales]) }
        stores = rs.sum { |r| num(r[col_store]) }
        per_store[biz] = sales / stores if stores.positive?
      end
    end

    detail = { "방식" => col_pps ? "점포당월매출_컬럼" : "월매출/점포수", "업종수" => per_store.size }
    if !per_store.key?(sel_biz) || per_store.empty?
      detail["note"] = "선택 업종 매출 데이터 없음"
      return [0, detail]
    end

    sel_val = per_store[sel_biz].to_f
    better = per_store.values.count { |v| v > sel_val }
    total = per_store.size
    top_ratio = better.to_f / total
    score = 0
    SALES_QUARTILE_RULES.each do |thr, pts|
      if top_ratio < thr
        score = pts
        break
      end
    end
    detail.merge!(
      "점포당월매출" => sel_val.round, "순위" => better + 1, "전체업종수" => total,
      "상위비율(%)" => (top_ratio * 100).round(1)
    )
    [score, detail]
  end

  def calculate_competition_score(region_rows, scolmap, sel_biz, sel_major)
    col_b, col_major, col_store = scolmap["업종"], scolmap["대분류"], scolmap["점포수"]
    major_rows = region_rows.select { |r| r[col_major] == sel_major }
    stores_by_biz = {}
    group_rows(major_rows, col_b).each { |biz, rs| stores_by_biz[biz] = rs.sum { |r| num(r[col_store]) } }

    detail = { "대분류" => sel_major, "대분류_업종수" => stores_by_biz.size }
    if !stores_by_biz.key?(sel_biz) || stores_by_biz.empty?
      detail["note"] = "선택 업종 점포수 데이터 없음"
      return [0, detail]
    end

    sel_stores = stores_by_biz[sel_biz].to_f
    med = median(stores_by_biz.values)
    ratio = med.positive? ? sel_stores / med : Float::INFINITY
    score = 0
    COMPETITION_RULES.each do |thr, pts|     # 큰 비율부터 평가
      if ratio >= thr
        score = pts
        break
      end
    end
    detail.merge!(
      "선택업종_점포수" => sel_stores.round, "대분류_점포수_중앙값" => med.round(1),
      "경쟁도비율" => ratio.round(2)
    )
    [score, detail]
  end

  def calculate_closure_score(region_rows, scolmap, sel_biz)
    col_b = scolmap["업종"]
    col_rate, col_closed, col_store = scolmap["폐업률"], scolmap["폐업점포수"], scolmap["점포수"]
    rows = region_rows.select { |r| r[col_b] == sel_biz }
    detail = {}
    if rows.empty?
      detail["note"] = "선택 업종 데이터 없음"
      return [0, detail]
    end

    rate_vals = col_rate ? rows.map { |r| r[col_rate] }.reject { |v| v.nil? || v.to_s.strip.empty? } : []
    if col_rate && !rate_vals.empty?
      rate = mean(rows.map { |r| num(r[col_rate]) })
      detail["방식"] = "폐업률_컬럼"
    else
      closed = col_closed ? rows.sum { |r| num(r[col_closed]) } : 0.0
      total = col_store ? rows.sum { |r| num(r[col_store]) } : 0.0
      rate = total.positive? ? (closed / total * 100) : 0.0
      detail["방식"] = "폐업점포수/전체점포수"
    end

    score = 0
    CLOSURE_RULES.each do |upper, pts|       # 작은 상한부터 평가
      if rate <= upper
        score = pts
        break
      end
    end
    detail["폐업률(%)"] = rate.round(1)
    [score, detail]
  end

  def calculate_wish_score(survey_rows, scolmap_s, sel_biz, canonical)
    cols = %w[희망업종_객관식 희망업종_주관식 부족업종].map { |k| scolmap_s[k] }.compact
    counter = Hash.new(0)
    cols.each do |col|
      column_values(survey_rows, col).each do |cell|
        split_multi(cell).each do |tok|
          mapped = match_business(tok, canonical)
          counter[mapped] += 1 if mapped
        end
      end
    end

    detail = {
      "집계컬럼" => cols, "선택업종_언급수" => counter[sel_biz].to_i,
      "상위언급" => most_common(counter, 5).to_h
    }
    if counter.empty? || !counter.key?(sel_biz)
      detail["순위"] = nil
      return [0, detail]
    end

    sel_count = counter[sel_biz]
    rank = 1 + counter.values.count { |c| c > sel_count }
    detail["순위"] = rank
    [WISH_RANK_RULES.fetch(rank, 0), detail]
  end

  def calculate_time_score(region_rows, scolmap, sel_biz, survey_rows, scolmap_s)
    col_b = scolmap["업종"]
    time_cols = scolmap["_time_cols"]
    detail = {}

    rows = region_rows.select { |r| r[col_b] == sel_biz }
    sales_peak = nil
    if !rows.empty? && !time_cols.empty?
      sums = {}
      time_cols.each { |slot, col| sums[slot] = rows.sum { |r| num(r[col]) } }
      sales_peak = sums.max_by { |_slot, v| v }&.first if sums.values.any?(&:positive?)
    end

    survey_peak = nil
    col_time = scolmap_s["이용시간"]
    if col_time
      slot_counter = Hash.new(0)
      column_values(survey_rows, col_time).each do |cell|
        split_multi(cell).each do |tok|
          SURVEY_TIME_KEYWORDS.each do |kw, slot|
            if tok.include?(kw)
              slot_counter[slot] += 1
              break
            end
          end
        end
      end
      survey_peak = most_common(slot_counter, 1).first&.first
    end

    detail.merge!("매출피크" => sales_peak, "학생이용피크" => survey_peak)
    if sales_peak.nil? || survey_peak.nil?
      detail["note"] = "피크 데이터 부족"
      return [0, detail]
    end

    diff = (TIME_SLOTS.index(sales_peak) - TIME_SLOTS.index(survey_peak)).abs
    detail["구간차이"] = diff
    [TIME_DIFF_RULES.fetch(diff, 0), detail]
  end

  def calculate_frequent_use_score(survey_rows, scolmap_s, sel_biz, sel_mid, canonical)
    col = scolmap_s["자주이용업종"]
    detail = { "언급수" => 0 }
    if col.nil?
      detail["note"] = "자주이용업종 컬럼 없음"
      return [0, detail]
    end

    mid_keys = sel_mid.to_s.split(/[·,\/]/).map(&:strip).reject(&:empty?)
    mentions = 0
    column_values(survey_rows, col).each do |cell|
      matched = split_multi(cell).any? do |tok|
        match_business(tok, canonical) == sel_biz ||
          mid_keys.any? { |k| tok.include?(k) || k.include?(tok) }
      end
      mentions += 1 if matched
    end

    detail["언급수"] = mentions
    [mentions.positive? ? FREQUENT_USE_POINT : 0, detail]
  end

  # ── low_score / demand_data 추출 ────────────────────────────────────────
  def reasons(item_key, d)
    case item_key
    when "점포당_월매출_순위"
      "점포당 월매출이 지역 #{d['전체업종수']}개 업종 중 #{d['순위']}위(상위 #{d['상위비율(%)']}%)로 낮은 편입니다."
    when "경쟁도"
      "동일 대분류 점포수 중앙값(#{d['대분류_점포수_중앙값']}) 대비 #{d['경쟁도비율']}배로 경쟁이 치열합니다."
    when "폐업률"
      "최근 폐업률이 #{d['폐업률(%)']}%로 높은 편입니다."
    when "더_생겼으면_좋을_가게"
      if d["순위"].nil?
        "수요조사에서 신규 수요 언급이 없어 잠재 수요가 약합니다."
      else
        "수요조사 희망업종 언급 순위 #{d['순위']}위로 신규 수요가 약한 편입니다."
      end
    when "상권_이용_시간대"
      if d["매출피크"].nil? || d["학생이용피크"].nil?
        "매출 시간대와 학생 이용 시간대를 비교할 데이터가 부족합니다."
      else
        "매출 피크(#{d['매출피크']})와 학생 이용 피크(#{d['학생이용피크']})가 #{d['구간차이']}구간 어긋납니다."
      end
    when "자주_이용하는_업종"
      "학생들이 자주 이용하는 업종 응답에 포함되지 않았습니다."
    else
      ""
    end
  end

  def extract_low_score_items(item_scores, item_details, item_max, improve_points)
    low = []
    item_scores.each do |key, score|
      thr = LOW_SCORE_THRESHOLDS[key]
      next if thr.nil? || score > thr

      low << {
        "항목" => key,
        "점수" => "#{score}/#{item_max[key]}",
        "낮은_이유" => reasons(key, item_details.fetch(key, {})),
        "개선_가능_포인트" => improve_points
      }
    end
    low
  end

  def extract_demand_data(survey_rows, scolmap_s)
    top_tokens = lambda do |col_key, exclude: [], n: 6|
      col = scolmap_s[col_key]
      return [] if col.nil?

      counter = Hash.new(0)
      column_values(survey_rows, col).each do |cell|
        split_multi(cell).each do |tok|
          counter[tok] += 1 if !tok.empty? && exclude.none? { |e| tok.include?(e) }
        end
      end
      most_common(counter, n).map(&:first)
    end

    pain = top_tokens.call("불편점", exclude: ["없음"], n: 6)
    wish = top_tokens.call("희망업종_객관식", n: 5)

    detail_col = scolmap_s["희망디테일"]
    wish_detail = []
    if detail_col
      seen = {}
      column_values(survey_rows, detail_col).each do |cell|
        txt = cell.to_s.strip
        if txt.length.between?(4, 40) && !seen.key?(txt)
          wish_detail << txt
          seen[txt] = true
        end
        break if wish_detail.size >= 3
      end
    end

    {
      "아쉽거나_불편한_점" => pain,
      "새로_생겼으면_좋을_포인트" => wish + wish_detail,
      "상권_이용_시간대" => top_tokens.call("이용시간", n: 4)
    }
  end

  # 그룹화 헬퍼 — 등장 순서 보존
  def group_rows(rows, col)
    grouped = {}
    rows.each do |r|
      key = r[col]
      next if key.nil?

      (grouped[key] ||= []) << r
    end
    grouped
  end

  def mean(values)
    return 0.0 if values.empty?

    values.sum.to_f / values.size
  end
end

# CLI 실행 (Rails 부팅 없이 단독 검증용):
#   bundle exec ruby app/services/business_score_service.rb
if __FILE__ == $PROGRAM_NAME
  require "set"
  user_input = {
    "업종" => "커피-음료",
    "대분류" => "음식·카페",
    "중분류" => "카페·베이커리",
    "위치" => "성신여대입구역 1번",
    "지역코드" => "3110303"
  }

  result = BusinessScoreService.call(
    user_input: user_input,
    store_sales_path: "data/store+sales.csv",
    survey_path: "data/survey.xlsx"
  )

  puts JSON.pretty_generate(result)
end
