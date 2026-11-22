import { HttpError } from '../http.js';
import { CompanyModel } from '../models/panel.js';
import { RideModel } from '../models/Ride.js';

// Empresas clientes: os colaboradores autorizados viajam "por conta da
// empresa". O passageiro não paga ao motorista; a empresa paga ao Bazá no fim
// do mês, e o Bazá credita o motorista (ver settleRide em rides.ts).

/** Início do mês corrente. */
export const monthStart = (d = new Date()) => new Date(d.getFullYear(), d.getMonth(), 1);

/** A empresa activa de que este número é colaborador autorizado, se houver. */
export async function companyFor(phone?: string | null) {
  if (!phone) return null;
  return CompanyModel.findOne({ active: true, members: { $elemMatch: { phone, active: true } } });
}

/** O que a empresa já gastou este mês (corridas feitas e em curso). */
export async function companySpent(companyId: unknown, from = monthStart()) {
  const [t] = await RideModel.aggregate<{ total: number }>([
    { $match: { company: companyId, createdAt: { $gte: from }, status: { $nin: ['cancelled', 'no_drivers'] } } },
    { $group: { _id: null, total: { $sum: '$fare' } } },
  ]);
  return t?.total ?? 0;
}

/** O que o app mostra ao colaborador: a empresa e quanto ainda pode gastar este mês. */
export async function companyStatus(phone?: string | null) {
  const company = await companyFor(phone);
  if (!company) return null;
  const spent = await companySpent(company._id);
  return {
    id: company.id as string,
    name: company.name,
    monthlyLimit: company.monthlyLimit,
    remaining: company.monthlyLimit > 0 ? Math.max(0, company.monthlyLimit - spent) : null,
  };
}

/** Confirma que a corrida cabe no limite da empresa; devolve a empresa a associar à corrida. */
export async function authorizeCompanyRide(phone: string | null | undefined, fare: number) {
  const company = await companyFor(phone);
  if (!company) throw new HttpError(403, 'O seu número não está autorizado a viajar por conta de uma empresa.');
  if (company.monthlyLimit > 0 && (await companySpent(company._id)) + fare > company.monthlyLimit) {
    throw new HttpError(402, `A ${company.name} atingiu o limite deste mês. Escolha outro pagamento.`);
  }
  return company;
}
