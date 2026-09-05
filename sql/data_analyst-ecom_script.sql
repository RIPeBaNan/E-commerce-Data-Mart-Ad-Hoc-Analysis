/* 
 * Проект: «Разработка витрины и решение ad-hoc задач»
 * Описание: Подготовка витрины данных маркетплейса «ВсёТут» и решение 4-х аналитических задач.
 * Автор: Наумов Илья
 * Дата: 12.07.2026
*/

/* Часть 1. Разработка витрины данных */

with order_filtered as (
	-- Фильтрация заказов по целевым статусам
	select *
	from ds_ecom.orders o
	where o.order_status in ('Доставлено', 'Отменено')
),
top_region as (
	-- Определение топ-3 регионов по общему количеству заказов
	select
		u.region,
		count(ofi.order_id) as total_orders
	from order_filtered ofi
	join ds_ecom.users u
		using (buyer_id)
	group by u.region
	order by total_orders desc
	limit 3
),
base_stats as (
	-- Сбор базовой информации по заказам в топ-3 регионах
	select
		ofi.order_id,
		u.user_id,
		u.region,
		ofi.order_purchase_ts,
		ofi.order_status
	from order_filtered ofi
	join ds_ecom.users u
		using(buyer_id)
	join top_region tr
		using(region)
),
order_cost as (
	-- Расчет итоговой стоимости каждого заказа с учетом доставки
	select
		oi.order_id,
		sum(oi.price + oi.delivery_cost) as order_cost
	from ds_ecom.order_items oi
	group by oi.order_id
),
review as (
	-- Нормализация оценок пользователей к 5-балльной шкале
	select
		ore.order_id,
		case
			when ore.review_score >= 10 and ore.review_score <= 50
				then ore.review_score::numeric(10, 2) / 10
			else ore.review_score::numeric(10, 2)
		end as review_score
	from ds_ecom.order_reviews ore
),
payments as (
	-- Установка бинарных флагов для способов оплаты (промокод, рассрочка, перевод)
	select
		op.order_id,
		max(case when op.payment_type = 'промокод' then 1 else 0 end) as used_promo,
		max(case when op.payment_installments > 1 then 1 else 0 end) used_installments,
		max(
			case
				when op.payment_sequential = 1 and op.payment_type = 'денежный перевод'
					then 1
				else 0
			end) as used_money_transfer
	from ds_ecom.order_payments op
	group by op.order_id
),
base_table as (
	-- Сборка промежуточной таблицы со всеми метриками для агрегации
	select
		bs.user_id,
    	bs.region,
    	bs.order_id,
    	bs.order_purchase_ts,
    	bs.order_status,
    	oc.order_cost,
    	r.review_score,
    	p.used_promo,
    	p.used_installments,
    	p.used_money_transfer
	from base_stats bs
	left join order_cost oc
		using(order_id)
	left join review r
		using(order_id)
	left join payments p
		using(order_id)
)
-- Формирование итоговой витрины данных
select
	user_id,
	region,
	min(order_purchase_ts)::timestamptz as first_order_ts,
	max(order_purchase_ts)::timestamptz as last_order_ts,
	(max(order_purchase_ts)::timestamptz - min(order_purchase_ts)::timestamptz) as lifetime,
	count(order_id) as total_orders,
	round(avg(review_score)::numeric, 2) as avg_order_rating,
	count(review_score) as num_orders_with_rating,
	count(case when order_status = 'Отменено' then 1 end) as num_canceled_orders,
	count(case when order_status = 'Отменено' then 1 end)::numeric(10, 2) / nullif(count(order_id), 0) as canceled_orders_ratio,
	sum(case when order_status = 'Доставлено' then order_cost end) as total_order_costs,
	round(avg(case when order_status = 'Доставлено' then order_cost end)::numeric, 2)::float as avg_order_cost,
	sum(used_installments) as num_installment_orders,
	sum(used_promo) as num_orders_with_promo,
	max(used_money_transfer) as used_money_transfer,
	max(used_installments) as used_installments,
	max(case when order_status = 'Отменено' then 1 else 0 end) as used_cancel
from base_table
group by user_id, region
order by total_orders desc;


/* Часть 2. Решение ad-hoc задач */

/* Задача 1. Сегментация пользователей по количеству совершенных заказов */
select
	case
		when total_orders >= 11 then '11 и более заказов'
		when total_orders >= 6 then '6–10 заказов'
		when total_orders >= 2 then '2—5 заказов'
		when total_orders = 1 then '1 заказ'
	end as user_group,
	count(distinct user_id) as total_user,
	round(avg(total_orders)::numeric, 2) as avg_orders,
	round(sum(total_order_costs)::numeric / nullif(sum(total_orders), 0), 2) as avg_costs
from ds_ecom.product_user_features puf
group by user_group
order by min(total_orders);
	
/* 
 * Выводы:
 * 1. Подавляющее число пользователей сделало только один заказ (доля возвращающихся пользователей крайне мала).
 * 2. При увеличении числа покупок наблюдается рост среднего чека, однако размер выборки для сегментов с 2+ заказами невелик.
*/


/* Задача 2. Ранжирование пользователей (топ-15 клиентов с 3+ заказами по среднему чеку) */

-- Вариант 1: С использованием оконной функции dense_rank()
with users_rank as (
	select
		*,
		dense_rank() over(order by avg_order_cost desc) as users_rank
	from ds_ecom.product_user_features puf 
	where puf.total_orders >= 3
)
select *
from users_rank
where users_rank <= 15;

-- Вариант 2: С использованием сортировки и ограничения limit
select *
from ds_ecom.product_user_features puf
where puf.total_orders >= 3
order by avg_order_cost desc
limit 15;
	
/* 
 * Выводы:
 * 1. Основная часть пользователей-лидеров совершала покупки в Москве.
 * 2. Данная группа крайне активна и оставляет отзывы на каждый заказ.
 * 3. Практически каждый из топ-пользователей пользовался рассрочкой.
 * 4. Только один покупатель из списка применил промокод.
 * 5. На 11-й позиции присутствует аномальный покупатель с высоким чеком, но жизненным циклом всего 2,5 дня.
*/


/* Задача 3. Статистика по регионам (клиенты, заказы, доли рассрочек и отмен) */
select 
	region,
	count(distinct user_id) as total_users,
	sum(total_orders) as total_order,
	round(sum(total_order_costs)::numeric / nullif(sum(total_orders), 0), 2) as avg_total_costs,
	round(sum(num_installment_orders)::numeric / nullif(sum(total_orders), 0), 4) as ratio_installments_orders,
	round(sum(num_orders_with_promo)::numeric / nullif(sum(total_orders), 0), 4) as ratio_promo_orders,
	round(sum(used_cancel)::numeric / count(distinct user_id), 4) as ratio_cancel_users
from ds_ecom.product_user_features puf
group by region;

/* 
 * Выводы:
 * 1. Москва лидирует по общему количеству заказов среди всех регионов.
 * 2. Около половины всех заказов оформляется с использованием рассрочки.
 * 3. Доля заказов с применением промокодов крайне мала и составляет ~ 4%.
 * 4. Процент отмен заказов очень низкий, что говорит о высокой доле выкупа.
*/


/* Задача 4. Когортный анализ активности пользователей по первому месяцу заказа в 2023 году */
with first_orders_2023 as(
	select *
	from ds_ecom.product_user_features puf 
	where first_order_ts >= '2023-01-01' and first_order_ts < '2024-01-01'
)
select
	extract(month from first_order_ts) as first_month_orders,
	count(distinct user_id) as total_users,
	sum(total_orders) as total_orders,
	round(sum(total_order_costs)::numeric / nullif(sum(total_orders), 0), 2) as avg_total_costs,
	round(avg(avg_order_rating)::numeric, 2) as avg_rating,
	round(sum(used_money_transfer)::numeric / nullif(count(distinct user_id), 0), 4) as money_transfer_ratio,
	avg(lifetime) as avg_lifetime
from first_orders_2023
group by first_month_orders
order by first_month_orders;

/* 
 * Выводы:
 * 1. В ноябре зафиксирован резкий приток новых пользователей (вероятно влияние распродаж и подготовки к праздникам).
 * 2. В осенний период заметно вырос средний чек, что объясняется сезонностью (покупка зимней одежды, подарков).
 * 3. Только ~20% пользователей оплачивали заказы денежным переводом.
 * 4. Начиная с октября, наблюдается падение среднего рейтинга, что может указывать на возросшую нагрузку на логистику.
 * 5. Жизненный цикл пользователей по-прежнему остаётся коротким — клиенты редко возвращаются за повторными покупками.
*/
