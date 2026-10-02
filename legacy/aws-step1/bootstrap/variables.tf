variable "region" {
  description = "Région AWS du staging (SES doit y recevoir des emails : eu-west-1 par défaut)."
  type        = string
  default     = "eu-west-1"
}

variable "github_owner" {
  description = "Propriétaire GitHub des repos kaxolax."
  type        = string
  default     = "synapsbranch-ux"
}
