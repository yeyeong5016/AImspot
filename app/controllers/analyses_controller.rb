# 모든 더미 데이터는 현재 하드코딩 상태입니다 (추후 DB/모델로 이전 예정).
class AnalysesController < ApplicationController
  # ── 홈 페이지 ──────────────────────────────────────────────
  def new
    @features = [
      { icon: "💰", title: "돈이 되나요?", desc: "업종별 점포당 매출과 수익성을 분석합니다" },
      { icon: "⚔️", title: "경쟁이 심한가요?", desc: "동종 업종 점포 수와 폐업률을 분석합니다" },
      { icon: "🎓", title: "학생들이 좋아하나요?", desc: "20대 여성 매출 비중과 소비 패턴을 분석합니다" },
      { icon: "📋", title: "학생들은 뭘 원하나요?", desc: "성신여대 학생 34명 수요조사 결과를 반영합니다" },
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
      { value: "34명", label: "학생 수요조사" },
      { value: "5개", label: "성신여대 상권" },
      { value: "2026년 1분기", label: "데이터 기준" }
    ]
  end

  # ── 상권 분석 리포트 페이지 ────────────────────────────────
  def show
    @areas = [
      { code: "A", label: "성신여대입구역 1번", lat: 37.5928, lng: 127.0168,
        polygon: [[37.5938, 127.0152], [37.5940, 127.0185], [37.5918, 127.0190], [37.5914, 127.0155]] },
      { code: "B", label: "성신여대입구역 4번", lat: 37.5919, lng: 127.0151 },
      { code: "C", label: "성신여대입구역 7번", lat: 37.5935, lng: 127.0179 },
      { code: "D", label: "보문역 8번", lat: 37.5854, lng: 127.0193 },
      { code: "E", label: "삼선동주민센터", lat: 37.5897, lng: 127.0079 }
    ]
    @station = { lat: 37.5926, lng: 127.0163, label: "성신여대입구역" }

    @code = params[:trdar_cd].presence || "A"
    @area = @areas.find { |a| a[:code] == @code } || @areas.first
    @biz  = params[:business_type].presence || "커피-음료"

    @ai_bullets = [
      "반경 300m 내 카페 64곳으로 포화 상태",
      "유동인구 일 평균 24,800명으로 충분",
      "디저트·브런치 결합 시 차별화 가능",
      "오전~심야 시간대 공백 수요 존재"
    ]

    @score = 23

    @revenue = [
      { name: "일반의원", value: 82 }, { name: "호프-간이주점", value: 59 },
      { name: "한식음식점", value: 51 }, { name: "슈퍼마켓", value: 42 },
      { name: "커피-음료", value: 39, highlight: true }, { name: "편의점", value: 28 },
      { name: "예술학원", value: 25 }, { name: "자동차수리", value: 21 },
      { name: "일반교습학원", value: 21 }, { name: "중식음식점", value: 20 }
    ]

    @competition = [
      { name: "F&B 업종군 중앙값", value: 14, kind: "muted" },
      { name: "커피-음료", value: 64, kind: "danger" }
    ]

    @age = [
      { name: "10대", value: 6 }, { name: "20대", value: 25, highlight: true },
      { name: "30대", value: 22 }, { name: "40대", value: 20 },
      { name: "50대", value: 16 }, { name: "60대+", value: 11 }
    ]
    @age_average = 19

    @timeslot = [
      { name: "00~06", sales: 8, students: 2 }, { name: "06~11", sales: 22, students: 5 },
      { name: "11~14", sales: 48, students: 9 }, { name: "14~17", sales: 35, students: 11 },
      { name: "17~21", sales: 41, students: 21 }, { name: "21~24", sales: 26, students: 14 }
    ]

    @problems = [
      { name: "비슷한 가게가 너무 많다", value: 17 },
      { name: "특별한 콘텐츠가 부족하다", value: 13 },
      { name: "늦게까지 운영하는 곳이 부족하다", value: 11 },
      { name: "공부할 공간이 부족하다", value: 8 },
      { name: "쉴 공간이 부족하다", value: 7 }
    ]

    @choice_criteria = [
      { rank: 1, label: "가격", count: 25 },
      { rank: 2, label: "품질", count: 21 },
      { rank: 3, label: "위치", count: 16 }
    ]

    @desired_biz = [
      { rank: 1, label: "식당(적당한 가격대)", count: 19 },
      { rank: 2, label: "24시간 공간", count: 15 },
      { rank: 3, label: "대형 카페", count: 14 }
    ]

    @strategies = [
      { id: "price", icon: "💰", title: "합리적 가격 설계",
        body: "학생 선택기준 1위 '가격'(73.5%) 반영. 7천원대 세트메뉴와 학생증 할인으로 재방문율 제고.",
        chip: "수요점수 88.2 · 선택기준", boost: 8, default_on: true },
      { id: "concept", icon: "🎨", title: "차별화 콘셉트 구축",
        body: "'비슷한 가게가 너무 많다' 50% 응답. 테마 메뉴·포토존·브랜드 경험으로 기억에 남는 가게 설계.",
        chip: "수요점수 50.0 · 상권문제점", boost: 11, default_on: false },
      { id: "space", icon: "🕐", title: "공간·운영시간 특화",
        body: "'24시간 공간' 희망 15명. 1인 공부석·콘센트·야간 운영으로 시험기간 수요 흡수.",
        chip: "수요점수 35.3 · 희망업종", boost: 15, default_on: false }
    ]
  end
end
