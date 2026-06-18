# 임시 데모 (UI, 입력창, 결과 출력 등   간단한 형태로 구현)

import streamlit as st

st.title("AImspot - 창업 분석 플랫폼")

location = st.text_input("창업 희망 위치")
business = st.text_input("업종")

if st.button("분석 시작"):
    st.success(f"{location}에서 {business} 창업 분석 시작")